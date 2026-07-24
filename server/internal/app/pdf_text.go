package app

import (
	"os"
	"strings"
	"sync"
	"time"

	"github.com/klippa-app/go-pdfium"
	"github.com/klippa-app/go-pdfium/requests"
	"github.com/klippa-app/go-pdfium/webassembly"
)

var (
	pdfiumPoolOnce sync.Once
	pdfiumPool     pdfium.Pool
	pdfiumPoolErr  error
)

func extractPDFPlainText(inputFile string) (string, error) {
	data, err := os.ReadFile(inputFile)
	if err != nil {
		return "", err
	}
	return extractPDFPlainTextFromBytes(data)
}

func extractPDFPlainTextFromBytes(data []byte) (string, error) {
	pdfiumPoolOnce.Do(func() {
		pdfiumPool, pdfiumPoolErr = webassembly.Init(webassembly.Config{
			MaxIdle:      2,
			MaxTotal:     2,
			ReuseWorkers: true,
		})
	})
	if pdfiumPoolErr != nil {
		return "", pdfiumPoolErr
	}

	instance, err := pdfiumPool.GetInstance(30 * time.Second)
	if err != nil {
		return "", err
	}
	defer instance.Close()

	doc, err := instance.OpenDocument(&requests.OpenDocument{File: &data})
	if err != nil {
		return "", err
	}
	defer instance.FPDF_CloseDocument(&requests.FPDF_CloseDocument{Document: doc.Document})

	pageCount, err := instance.FPDF_GetPageCount(&requests.FPDF_GetPageCount{Document: doc.Document})
	if err != nil {
		return "", err
	}
	parts := make([]string, 0, pageCount.PageCount)
	for index := 0; index < pageCount.PageCount; index++ {
		text, err := instance.GetPageText(&requests.GetPageText{
			Page: requests.Page{ByIndex: &requests.PageByIndex{Document: doc.Document, Index: index}},
		})
		if err != nil {
			return "", err
		}
		parts = append(parts, text.Text)
	}
	return strings.Join(parts, "\n"), nil
}
