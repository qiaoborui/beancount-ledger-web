package app

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	degcompiler "github.com/deb-sig/double-entry-generator/v2/pkg/compiler"
	degconfig "github.com/deb-sig/double-entry-generator/v2/pkg/config"
	"github.com/deb-sig/double-entry-generator/v2/pkg/consts"
	degprovider "github.com/deb-sig/double-entry-generator/v2/pkg/provider"
	"github.com/deb-sig/double-entry-generator/v2/pkg/provider/wechat"
	"github.com/spf13/viper"
)

type importEngine interface {
	ID() string
	RequiredFiles(importProviderConfig) []string
	Generate(context.Context, *Server, importEngineInput) error
}

type importEngineInput struct {
	ProviderID string
	Config     importProviderConfig
	InputFile  string
	OutputFile string
}

type degModuleImportEngine struct{}

func (degModuleImportEngine) ID() string {
	return "deg-module"
}

func (degModuleImportEngine) RequiredFiles(config importProviderConfig) []string {
	return []string{"main.bean", config.Config, "scripts/dedup_import.py"}
}

func (degModuleImportEngine) Generate(ctx context.Context, s *Server, input importEngineInput) error {
	config, err := loadDEGModuleConfig(s.cfg, input.Config)
	if err != nil {
		return err
	}
	degProviderID := input.ProviderID
	if input.Config.DEGProviderID != "" {
		degProviderID = input.Config.DEGProviderID
	}
	provider, err := degprovider.New(degProviderID)
	if err != nil {
		return err
	}
	applyDEGModuleProviderConfig(degProviderID, provider, config)
	ir, err := provider.Translate(input.InputFile)
	if err != nil {
		return err
	}
	compiler, err := degcompiler.New(degProviderID, consts.CompilerBeanCount, input.OutputFile, false, config, ir)
	if err != nil {
		return err
	}
	return compiler.Compile()
}

func loadDEGModuleConfig(appConfig Config, providerConfig importProviderConfig) (*degconfig.Config, error) {
	configFile := filepath.Join(appConfig.LedgerRoot, providerConfig.Config)
	reader := viper.New()
	reader.SetConfigFile(configFile)
	if err := reader.ReadInConfig(); err != nil {
		return nil, fmt.Errorf("读取 DEG 配置失败 %s: %w", providerConfig.Config, err)
	}
	config := &degconfig.Config{}
	if err := reader.Unmarshal(config); err != nil {
		return nil, fmt.Errorf("解析 DEG 配置失败 %s: %w", providerConfig.Config, err)
	}
	return config, nil
}

func applyDEGModuleProviderConfig(providerID string, provider degprovider.Interface, config *degconfig.Config) {
	if providerID == consts.ProviderWechat {
		if wechatProvider, ok := provider.(*wechat.Wechat); ok && strings.EqualFold(strings.TrimSpace(os.Getenv("DEG_WECHAT_IGNORE_INVALID_TX_TYPES")), "true") {
			wechatProvider.IgnoreInvalidTxTypes = true
		}
	}
}

func degImportEngine() importEngine {
	return degModuleImportEngine{}
}

type nativeBeanImportEngine struct {
	id       string
	generate func(*Server, context.Context, string, string) error
}

func (engine nativeBeanImportEngine) ID() string {
	if engine.id == "" {
		return "native"
	}
	return engine.id
}

func (nativeBeanImportEngine) RequiredFiles(config importProviderConfig) []string {
	return []string{"main.bean", config.Config, "scripts/dedup_import.py"}
}

func (engine nativeBeanImportEngine) Generate(ctx context.Context, s *Server, input importEngineInput) error {
	return engine.generate(s, ctx, input.InputFile, input.OutputFile)
}

func nativeImportEngine(id string, generate func(*Server, context.Context, string, string) error) importEngine {
	return nativeBeanImportEngine{id: id, generate: generate}
}
