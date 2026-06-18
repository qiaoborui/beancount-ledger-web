package app

type BeanLoadResult struct {
	Entries    []BeanSDKEntry        `json:"entries"`
	Errors     []BeanParseError      `json:"errors"`
	OptionsMap map[string]string     `json:"optionsMap"`
	Plugins    []BeanSDKPlugin       `json:"plugins,omitempty"`
	Includes   []BeanSDKInclude      `json:"includes,omitempty"`
	Directives []BeanSDKControlEntry `json:"directives,omitempty"`
}

type BeanSDKMeta struct {
	Filename string `json:"filename"`
	Lineno   int    `json:"lineno"`
}

type BeanSDKAmount struct {
	Number   string `json:"number"`
	Currency string `json:"currency"`
}

type BeanSDKPosting struct {
	Account    string         `json:"account"`
	Units      *BeanSDKAmount `json:"units,omitempty"`
	Cost       *BeanSDKAmount `json:"cost,omitempty"`
	CostTotal  bool           `json:"costTotal,omitempty"`
	Price      *BeanSDKAmount `json:"price,omitempty"`
	PriceTotal bool           `json:"priceTotal,omitempty"`
	Flag       string         `json:"flag,omitempty"`
}

type BeanSDKEntry struct {
	Type        string                   `json:"type"`
	Meta        BeanSDKMeta              `json:"meta"`
	Date        string                   `json:"date,omitempty"`
	Flag        string                   `json:"flag,omitempty"`
	Payee       string                   `json:"payee,omitempty"`
	Narration   string                   `json:"narration,omitempty"`
	Tags        []string                 `json:"tags,omitempty"`
	Links       []string                 `json:"links,omitempty"`
	Postings    []BeanSDKPosting         `json:"postings,omitempty"`
	Account     string                   `json:"account,omitempty"`
	Source      string                   `json:"source,omitempty"`
	Currencies  []string                 `json:"currencies,omitempty"`
	Currency    string                   `json:"currency,omitempty"`
	Amount      *BeanSDKAmount           `json:"amount,omitempty"`
	Tolerance   string                   `json:"tolerance,omitempty"`
	Filename    string                   `json:"filename,omitempty"`
	EventType   string                   `json:"eventType,omitempty"`
	Description string                   `json:"description,omitempty"`
	QueryName   string                   `json:"queryName,omitempty"`
	QueryString string                   `json:"queryString,omitempty"`
	CustomType  string                   `json:"customType,omitempty"`
	Values      []MetadataValue          `json:"values,omitempty"`
	Metadata    map[string]MetadataValue `json:"metadata,omitempty"`
}

type BeanSDKPlugin struct {
	Meta   BeanSDKMeta `json:"meta"`
	Module string      `json:"module"`
	Config string      `json:"config,omitempty"`
}

type BeanSDKInclude struct {
	Meta     BeanSDKMeta `json:"meta"`
	Filename string      `json:"filename"`
}

type BeanSDKControlEntry struct {
	Type     string                   `json:"type"`
	Meta     BeanSDKMeta              `json:"meta"`
	Tags     []string                 `json:"tags,omitempty"`
	Name     string                   `json:"name,omitempty"`
	Metadata map[string]MetadataValue `json:"metadata,omitempty"`
}

func LoadBeanFile(filename string) (BeanLoadResult, error) {
	lines, err := ReadLedgerLines(filename, map[string]bool{})
	if err != nil {
		return BeanLoadResult{}, err
	}
	return LoadBeanLines(lines), nil
}

func LoadBeanLines(lines []BeanLine) BeanLoadResult {
	compiled := CompileBeanLines(lines)
	return BeanLoadResultFromEntries(compiled.Entries, compiled.Errors)
}

func BeanLoadResultFromEntries(entries []BeanEntry, errors []BeanParseError) BeanLoadResult {
	return BeanLoadResult{
		Entries:    SDKEntriesFromBeanEntries(entries),
		Errors:     append([]BeanParseError{}, errors...),
		OptionsMap: OptionsMapFromBeanEntries(entries),
		Plugins:    SDKPluginsFromBeanEntries(entries),
		Includes:   SDKIncludesFromBeanEntries(entries),
		Directives: SDKControlEntriesFromBeanEntries(entries),
	}
}

func SDKEntriesFromBeanEntries(entries []BeanEntry) []BeanSDKEntry {
	out := []BeanSDKEntry{}
	for _, entry := range entries {
		if sdkEntry, ok := sdkEntry(entry); ok {
			out = append(out, sdkEntry)
		}
	}
	return out
}

func SDKPluginsFromBeanEntries(entries []BeanEntry) []BeanSDKPlugin {
	out := []BeanSDKPlugin{}
	for _, entry := range entries {
		if entry.Kind == "plugin" {
			out = append(out, BeanSDKPlugin{Meta: sdkMeta(entry), Module: entry.Name, Config: entry.Value})
		}
	}
	return out
}

func SDKIncludesFromBeanEntries(entries []BeanEntry) []BeanSDKInclude {
	out := []BeanSDKInclude{}
	for _, entry := range entries {
		if entry.Kind == "include" {
			out = append(out, BeanSDKInclude{Meta: sdkMeta(entry), Filename: entry.Filename})
		}
	}
	return out
}

func SDKControlEntriesFromBeanEntries(entries []BeanEntry) []BeanSDKControlEntry {
	out := []BeanSDKControlEntry{}
	for _, entry := range entries {
		switch entry.Kind {
		case "pushtag", "poptag", "pushmeta", "popmeta":
			out = append(out, sdkControlEntry(entry))
		}
	}
	return out
}

func OptionsMapFromBeanEntries(entries []BeanEntry) map[string]string {
	options := map[string]string{}
	for _, entry := range entries {
		if entry.Kind == "option" {
			options[entry.Name] = entry.Value
		}
	}
	return options
}

func copyStringMap(input map[string]string) map[string]string {
	out := make(map[string]string, len(input))
	for key, value := range input {
		out[key] = value
	}
	return out
}

func sdkEntry(entry BeanEntry) (BeanSDKEntry, bool) {
	out := BeanSDKEntry{
		Type:     sdkEntryType(entry.Kind),
		Meta:     sdkMeta(entry),
		Date:     entry.Date,
		Tags:     append([]string{}, entry.Tags...),
		Links:    append([]string{}, entry.Links...),
		Metadata: sdkMetadata(entry.Metadata),
	}
	switch entry.Kind {
	case "transaction":
		out.Flag = entry.Flag
		out.Payee = entry.Payee
		out.Narration = entry.Narration
		out.Postings = sdkPostings(entry.Postings)
	case "open":
		out.Account = entry.Account
		out.Currencies = append([]string{}, entry.Currencies...)
	case "close":
		out.Account = entry.Account
	case "commodity":
		out.Currency = entry.Currency
	case "price":
		out.Currency = entry.Currency
		out.Amount = sdkAmountPtr(entry.AmountValue)
	case "balance":
		out.Account = entry.Account
		out.Amount = sdkAmountPtr(entry.AmountValue)
		out.Tolerance = entry.Tolerance
	case "pad":
		out.Account = entry.Account
		out.Source = entry.Account2
	case "note":
		out.Account = entry.Account
		out.Narration = entry.Narration
	case "document":
		out.Account = entry.Account
		out.Filename = entry.Filename
	case "event":
		out.EventType = entry.Name
		out.Description = entry.Value
	case "query":
		out.QueryName = entry.Name
		out.QueryString = entry.Value
	case "custom":
		out.CustomType = entry.CustomType
		out.Values = append([]MetadataValue{}, entry.CustomValues...)
	default:
		return BeanSDKEntry{}, false
	}
	if len(out.Metadata) == 0 {
		out.Metadata = nil
	}
	return out, true
}

func sdkPostings(postings []parsedPosting) []BeanSDKPosting {
	out := make([]BeanSDKPosting, 0, len(postings))
	for _, posting := range postings {
		row := BeanSDKPosting{
			Account:    posting.Account,
			Units:      sdkAmountPtr(posting.Quantity),
			Cost:       sdkAmountPtr(posting.Cost),
			CostTotal:  posting.TotalCost,
			Price:      sdkAmountPtr(posting.Price),
			PriceTotal: posting.TotalPrice,
			Flag:       posting.Flag,
		}
		if posting.Blank {
			row.Units = nil
		}
		out = append(out, row)
	}
	return out
}

func sdkAmountPtr(amount BeanAmount) *BeanSDKAmount {
	if amount.Number == "" && amount.Currency == "" {
		return nil
	}
	return &BeanSDKAmount{Number: amount.Number, Currency: amount.Currency}
}

func sdkControlEntry(entry BeanEntry) BeanSDKControlEntry {
	out := BeanSDKControlEntry{Type: sdkEntryType(entry.Kind), Meta: sdkMeta(entry), Tags: append([]string{}, entry.Tags...), Name: entry.Name, Metadata: sdkMetadata(entry.Metadata)}
	if len(out.Metadata) == 0 {
		out.Metadata = nil
	}
	return out
}

func sdkMeta(entry BeanEntry) BeanSDKMeta {
	return BeanSDKMeta{Filename: entry.File, Lineno: entry.Line}
}

func sdkMetadata(metadata map[string]MetadataValue) map[string]MetadataValue {
	if len(metadata) == 0 {
		return nil
	}
	out := make(map[string]MetadataValue, len(metadata))
	for key, value := range metadata {
		out[key] = value
	}
	return out
}

func sdkEntryType(kind string) string {
	switch kind {
	case "transaction":
		return "Transaction"
	case "open":
		return "Open"
	case "close":
		return "Close"
	case "commodity":
		return "Commodity"
	case "price":
		return "Price"
	case "balance":
		return "Balance"
	case "pad":
		return "Pad"
	case "note":
		return "Note"
	case "document":
		return "Document"
	case "event":
		return "Event"
	case "query":
		return "Query"
	case "custom":
		return "Custom"
	case "pushtag":
		return "PushTag"
	case "poptag":
		return "PopTag"
	case "pushmeta":
		return "PushMeta"
	case "popmeta":
		return "PopMeta"
	default:
		return kind
	}
}
