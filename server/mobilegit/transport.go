package mobilegit

import (
	"context"
	"errors"
	"io"
	"net/http"
	"net/url"
	"strings"

	git "github.com/go-git/go-git/v5"
	"github.com/go-git/go-git/v5/config"
	"github.com/go-git/go-git/v5/plumbing"
	"github.com/go-git/go-git/v5/plumbing/protocol/packp"
	"github.com/go-git/go-git/v5/plumbing/transport"
	"github.com/go-git/go-git/v5/plumbing/transport/client"
	githttp "github.com/go-git/go-git/v5/plumbing/transport/http"
)

func init() {
	// Remove transports that may start a subprocess or use plaintext. Only
	// tests install an in-process file transport after package initialization.
	for _, scheme := range []string{"http", "ssh", "git", "file"} {
		client.InstallProtocol(scheme, nil)
	}
	httpClient := &http.Client{Transport: boundedHTTPTransport{http.DefaultTransport}, CheckRedirect: sameHostHTTPSRedirect}
	client.InstallProtocol("https", guardedTransport{githttp.NewClient(httpClient)})
}

func sameHostHTTPSRedirect(next *http.Request, previous []*http.Request) error {
	if len(previous) >= 5 || next.URL.Scheme != "https" || next.URL.User != nil || len(previous) == 0 || !strings.EqualFold(next.URL.Host, previous[0].URL.Host) {
		return fail("invalid_request", "Git redirects must remain on the original HTTPS host")
	}
	return nil
}

type boundedHTTPTransport struct{ http.RoundTripper }

func (t boundedHTTPTransport) RoundTrip(request *http.Request) (*http.Response, error) {
	response, err := t.RoundTripper.RoundTrip(request)
	if err != nil {
		return nil, err
	}
	limit := int64(8 << 20)
	if request.Method == http.MethodPost && strings.HasSuffix(request.URL.Path, "/git-upload-pack") {
		limit = maxTotalBytes
	}
	if response.ContentLength > limit {
		response.Body.Close()
		return nil, fail("limit_exceeded", "Git HTTP response exceeds the local transfer budget")
	}
	response.Body = &boundedHTTPBody{ReadCloser: response.Body, remaining: limit}
	return response, nil
}

type boundedHTTPBody struct {
	io.ReadCloser
	remaining int64
}

func (r *boundedHTTPBody) Read(p []byte) (int, error) {
	if int64(len(p)) > r.remaining+1 {
		p = p[:r.remaining+1]
	}
	n, err := r.ReadCloser.Read(p)
	if int64(n) > r.remaining {
		return 0, fail("limit_exceeded", "Git HTTP response exceeds the local transfer budget")
	}
	r.remaining -= int64(n)
	return n, err
}

func validateRemote(raw, branch string, allowFileFixture bool) error {
	parsed, err := url.Parse(raw)
	if err != nil || parsed.User != nil || parsed.RawQuery != "" || parsed.Fragment != "" {
		return fail("invalid_request", "Git URL must use HTTPS without embedded credentials, query, or fragment")
	}
	valid := parsed.Scheme == "https" && parsed.Hostname() != "" && parsed.Path != ""
	if allowFileFixture {
		valid = valid || (parsed.Scheme == "file" && parsed.Host == "" && strings.HasPrefix(parsed.Path, "/"))
	}
	if !valid {
		return fail("invalid_request", "Git URL must use HTTPS")
	}
	if branch == "" || len(branch) > 200 || strings.HasPrefix(branch, "refs/") || plumbing.NewBranchReferenceName(branch).Validate() != nil {
		return fail("invalid_request", "Invalid Git branch name")
	}
	return nil
}

func ephemeralRemote(repository *git.Repository, input request) (*git.Remote, transport.AuthMethod) {
	remote := git.NewRemote(repository.Storer, &config.RemoteConfig{Name: "origin", URLs: []string{input.URL}})
	var auth transport.AuthMethod
	if input.Password != "" {
		username := input.Username
		if username == "" {
			username = "x-access-token"
		}
		auth = &githttp.BasicAuth{Username: username, Password: input.Password}
	}
	return remote, auth
}

func fetch(ctx context.Context, repository *git.Repository, input request) (any, error) {
	storage, err := newFetchStorage(ctx, repository.Storer, input.StorageRoot)
	if err != nil {
		return nil, err
	}
	// Advertise only remote-tracking commits. Local proposals are not known to
	// the server and do not establish a shared object boundary.
	remote := git.NewRemote(storage, &config.RemoteConfig{Name: "origin", URLs: []string{input.URL}})
	_, auth := ephemeralRemote(repository, input)
	references, err := remote.ListContext(ctx, &git.ListOptions{Auth: auth})
	if err != nil && !errors.Is(err, transport.ErrEmptyRemoteRepository) {
		return nil, err
	}
	refName := plumbing.NewBranchReferenceName(input.Branch)
	tracking := plumbing.ReferenceName("refs/remotes/origin/" + input.Branch)
	exists := false
	for _, reference := range references {
		if reference.Name() == refName {
			exists = true
			break
		}
	}
	if !exists {
		if err := repository.Storer.RemoveReference(tracking); err != nil && !errors.Is(err, plumbing.ErrReferenceNotFound) {
			return nil, err
		}
		return map[string]any{"remoteHead": "", "branchExists": false}, nil
	}
	err = remote.FetchContext(ctx, &git.FetchOptions{RemoteName: "origin", Auth: auth, Tags: git.NoTags,
		RefSpecs: []config.RefSpec{config.RefSpec("+" + refName.String() + ":" + tracking.String())}})
	if err != nil && !errors.Is(err, git.NoErrAlreadyUpToDate) {
		return nil, err
	}
	head, err := repository.Reference(tracking, true)
	if err != nil {
		return nil, err
	}
	if _, err := repository.CommitObject(head.Hash()); err != nil {
		return nil, err
	}
	return map[string]any{"remoteHead": head.Hash().String(), "branchExists": true}, nil
}

type remoteExpectation struct {
	branch plumbing.ReferenceName
	hash   plumbing.Hash
}
type expectationContextKey struct{}

// The expectation is checked on the same receive-pack advertisement used to
// construct the protocol's Old→New update. This covers a previously absent
// branch as well as a concurrent change between fetch and push.
type guardedTransport struct{ transport.Transport }

func (t guardedTransport) NewReceivePackSession(endpoint *transport.Endpoint, auth transport.AuthMethod) (transport.ReceivePackSession, error) {
	session, err := t.Transport.NewReceivePackSession(endpoint, auth)
	if err != nil {
		return nil, err
	}
	return guardedReceiveSession{session}, nil
}

type guardedReceiveSession struct{ transport.ReceivePackSession }

func (s guardedReceiveSession) AdvertisedReferencesContext(ctx context.Context) (*packp.AdvRefs, error) {
	references, err := s.ReceivePackSession.AdvertisedReferencesContext(ctx)
	if err != nil {
		return nil, err
	}
	if expected, ok := ctx.Value(expectationContextKey{}).(remoteExpectation); ok {
		all, err := references.AllReferences()
		if err != nil {
			return nil, err
		}
		actual := plumbing.ZeroHash
		if reference, err := all.Reference(expected.branch); err == nil {
			actual = reference.Hash()
		} else if !errors.Is(err, plumbing.ErrReferenceNotFound) {
			return nil, err
		}
		if actual != expected.hash {
			return nil, fail("remote_changed", "Remote branch changed; fetch and reconcile before pushing")
		}
	}
	return references, nil
}

func push(ctx context.Context, repository *git.Repository, input request) (any, error) {
	commitHash, err := parseCommit(input.Commit, false)
	if err != nil {
		return nil, err
	}
	expectedHash, err := parseCommit(*input.ExpectedRemoteHead, true)
	if err != nil {
		return nil, err
	}
	commit, err := repository.CommitObject(commitHash)
	if err != nil {
		return nil, err
	}
	if !expectedHash.IsZero() {
		ancestor, err := isAncestor(ctx, repository, expectedHash, commitHash)
		if err != nil {
			return nil, err
		}
		if !ancestor {
			return nil, fail("non_fast_forward", "Commit must descend from expectedRemoteHead")
		}
	} else if len(commit.ParentHashes) != 0 {
		return nil, fail("non_fast_forward", "Creating a remote branch requires a root commit")
	}
	remote, auth := ephemeralRemote(repository, input)
	branch := plumbing.NewBranchReferenceName(input.Branch)
	ctx = context.WithValue(ctx, expectationContextKey{}, remoteExpectation{branch: branch, hash: expectedHash})
	options := &git.PushOptions{RemoteName: "origin", Auth: auth, Force: false,
		RefSpecs: []config.RefSpec{config.RefSpec(commitHash.String() + ":" + branch.String())}}
	if !expectedHash.IsZero() {
		options.RequireRemoteRefs = []config.RefSpec{config.RefSpec(expectedHash.String() + ":" + branch.String())}
	}
	if err := remote.PushContext(ctx, options); err != nil && !errors.Is(err, git.NoErrAlreadyUpToDate) {
		return nil, err
	}
	if err := repository.Storer.SetReference(plumbing.NewHashReference(plumbing.ReferenceName("refs/remotes/origin/"+input.Branch), commitHash)); err != nil {
		return nil, err
	}
	return map[string]string{"remoteHead": commitHash.String()}, nil
}

func isAncestor(ctx context.Context, repository *git.Repository, ancestor, descendant plumbing.Hash) (bool, error) {
	pending := []plumbing.Hash{descendant}
	seen := map[plumbing.Hash]bool{}
	for len(pending) > 0 {
		if err := ctx.Err(); err != nil {
			return false, err
		}
		current := pending[len(pending)-1]
		pending = pending[:len(pending)-1]
		if current == ancestor {
			return true, nil
		}
		if seen[current] {
			continue
		}
		seen[current] = true
		if len(seen) > 100000 {
			return false, fail("limit_exceeded", "Git ancestry exceeds 100000 commits")
		}
		commit, err := repository.CommitObject(current)
		if err != nil {
			return false, err
		}
		pending = append(pending, commit.ParentHashes...)
	}
	return false, nil
}
