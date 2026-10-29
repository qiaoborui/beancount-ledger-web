package app

import (
	"bytes"
	"os"
	"path/filepath"
	"testing"

	degalipay "github.com/deb-sig/double-entry-generator/v2/pkg/analyser/alipay"
	degconfig "github.com/deb-sig/double-entry-generator/v2/pkg/config"
	"github.com/deb-sig/double-entry-generator/v2/pkg/ir"
	"github.com/spf13/viper"
)

// The shipped example config is the template users copy. A fund purchase must
// keep the account of the method that actually paid for it.
func TestExampleAlipayConfigFundPurchaseKeepsPaymentMethodAccount(t *testing.T) {
	raw, err := os.ReadFile(filepath.Join("..", "..", "..", "examples", "preview-ledger", "imports", "alipay-config.yaml"))
	if err != nil {
		t.Fatal(err)
	}
	reader := viper.New()
	reader.SetConfigType("yaml")
	if err := reader.ReadConfig(bytes.NewReader(raw)); err != nil {
		t.Fatal(err)
	}
	config := &degconfig.Config{}
	if err := reader.Unmarshal(config); err != nil {
		t.Fatal(err)
	}

	for method, want := range map[string]string{
		"余额宝":           "Assets:CN:Alipay:Balance",
		"招商银行储蓄卡(1305)": "Assets:CN:Bank:PrimaryChecking",
		"招商银行信用卡(0016)": "Liabilities:CN:CreditCard",
		"网商银行(互联网银行)":   "Assets:CN:DigitalBank:Yulibao",
	} {
		order := &ir.Order{
			Peer: "蚂蚁财富-蚂蚁（杭州）基金销售有限公司", Item: "蚂蚁财富-纳斯达克100指数(QDII)A-买入",
			Category: "投资理财", TypeOriginal: "不计收支", Type: ir.TypeSend, Method: method, Money: 9.99,
		}
		_, minus, plus, _, _ := degalipay.Alipay{}.GetAccountsAndTags(order, config, "", "alipay")
		if minus != want || plus != "Assets:CN:Alipay:Fund" {
			t.Errorf("method %s: got %s -> %s, want %s -> Assets:CN:Alipay:Fund", method, minus, plus, want)
		}
	}
}
