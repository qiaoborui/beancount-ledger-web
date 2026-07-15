package app

import (
	"archive/zip"
	"bytes"
	"compress/flate"
	"context"
	"encoding/binary"
	"errors"
	"fmt"
	"hash/crc32"
	"io"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"sync/atomic"
)

const (
	zipPasswordSpace          = 1_000_000
	zipLocalHeaderSignature   = 0x04034b50
	zipCentralHeaderSignature = 0x02014b50
	zipEndHeaderSignature     = 0x06054b50
	zip64Marker               = 0xffffffff
	zipSearchChunkSize        = 4096
	maxImportArchiveEntries   = 20
	maxImportFileBytes        = 10 * 1024 * 1024
)

var importZipCRCTable = crc32.MakeTable(crc32.IEEE)

type encryptedZipEntry struct {
	name             []byte
	flags            uint16
	method           uint16
	crc              uint32
	uncompressedSize uint64
	encrypted        []byte
	checkByte        byte
}

type zipCryptoKeys struct {
	key0 uint32
	key1 uint32
	key2 uint32
}

func extractImportZIP(ctx context.Context, archive []byte, passwordCandidates []string) (importUpload, string, error) {
	if len(archive) > maxImportFileBytes {
		return importUpload{}, "", errors.New("压缩包超过 10MB")
	}
	if upload, err := extractPlainImportZIP(archive); err == nil {
		return upload, "", nil
	}
	entry, err := loadEncryptedZipEntry(archive)
	if err != nil {
		return importUpload{}, "", err
	}
	for _, password := range passwordCandidates {
		if plain, ok := decryptZipEntryWithPassword(entry, []byte(password)); ok {
			return importUpload{Filename: safeArchiveFilename(string(entry.name)), Content: plain}, password, nil
		}
	}
	password, plain, found := searchNumericZipPasswords(ctx, entry, min(runtime.NumCPU(), 4))
	if !found {
		if err := ctx.Err(); err != nil {
			return importUpload{}, "", fmt.Errorf("压缩包密码搜索超时: %w", err)
		}
		return importUpload{}, "", errors.New("压缩包密码不在 000000-999999 范围内")
	}
	return importUpload{Filename: safeArchiveFilename(string(entry.name)), Content: plain}, fmt.Sprintf("%06d", password), nil
}

func extractPlainImportZIP(archive []byte) (importUpload, error) {
	reader, err := zip.NewReader(bytes.NewReader(archive), int64(len(archive)))
	if err != nil {
		return importUpload{}, err
	}
	if len(reader.File) > maxImportArchiveEntries {
		return importUpload{}, fmt.Errorf("压缩包文件数量超过 %d", maxImportArchiveEntries)
	}
	for _, file := range reader.File {
		if file.FileInfo().IsDir() || file.Flags&1 != 0 {
			continue
		}
		if !potentialImportArchiveFile(file.Name) {
			continue
		}
		if file.UncompressedSize64 > maxImportFileBytes {
			return importUpload{}, errors.New("压缩包内账单超过 10MB")
		}
		body, err := file.Open()
		if err != nil {
			continue
		}
		content, readErr := io.ReadAll(io.LimitReader(body, maxImportFileBytes+1))
		closeErr := body.Close()
		if readErr != nil || closeErr != nil {
			continue
		}
		if len(content) > maxImportFileBytes {
			return importUpload{}, errors.New("压缩包内账单超过 10MB")
		}
		return importUpload{Filename: safeArchiveFilename(file.Name), Content: content}, nil
	}
	return importUpload{}, errors.New("压缩包中没有可读取的文件")
}

func potentialImportArchiveFile(name string) bool {
	switch strings.ToLower(filepath.Ext(name)) {
	case ".csv", ".xlsx", ".xls", ".eml", ".html", ".htm", ".pdf":
		return true
	default:
		return false
	}
}

func safeArchiveFilename(name string) string {
	name = strings.ReplaceAll(name, "\\", "/")
	base := filepath.Base(name)
	if base == "" || base == "." || base == ".." {
		return "statement"
	}
	return base
}

func loadEncryptedZipEntry(archive []byte) (*encryptedZipEntry, error) {
	endOffset, err := findZipEndHeader(archive)
	if err != nil {
		return nil, err
	}
	endHeader := archive[endOffset:]
	if binary.LittleEndian.Uint16(endHeader[4:6]) != 0 || binary.LittleEndian.Uint16(endHeader[6:8]) != 0 {
		return nil, errors.New("暂不支持分卷 ZIP")
	}
	entryCount := int(binary.LittleEndian.Uint16(endHeader[10:12]))
	if entryCount > maxImportArchiveEntries {
		return nil, fmt.Errorf("压缩包文件数量超过 %d", maxImportArchiveEntries)
	}
	position := int(binary.LittleEndian.Uint32(endHeader[16:20]))
	for index := 0; index < entryCount; index++ {
		if position < 0 || position+46 > len(archive) {
			return nil, errors.New("ZIP 中央目录不完整")
		}
		header := archive[position : position+46]
		if binary.LittleEndian.Uint32(header[0:4]) != zipCentralHeaderSignature {
			return nil, errors.New("ZIP 中央目录签名无效")
		}
		nameLength := int(binary.LittleEndian.Uint16(header[28:30]))
		extraLength := int(binary.LittleEndian.Uint16(header[30:32]))
		commentLength := int(binary.LittleEndian.Uint16(header[32:34]))
		recordEnd := position + 46 + nameLength + extraLength + commentLength
		if recordEnd > len(archive) {
			return nil, errors.New("ZIP 中央目录条目不完整")
		}
		name := archive[position+46 : position+46+nameLength]
		flags := binary.LittleEndian.Uint16(header[8:10])
		if flags&1 != 0 && !bytes.HasSuffix(name, []byte("/")) {
			compressedSize := binary.LittleEndian.Uint32(header[20:24])
			uncompressedSize := binary.LittleEndian.Uint32(header[24:28])
			localOffset := binary.LittleEndian.Uint32(header[42:46])
			if compressedSize == zip64Marker || uncompressedSize == zip64Marker || localOffset == zip64Marker {
				return nil, errors.New("暂不支持 ZIP64 加密账单")
			}
			if uncompressedSize > maxImportFileBytes {
				return nil, errors.New("压缩包内账单超过 10MB")
			}
			return parseEncryptedZipLocalEntry(archive, name, flags, binary.LittleEndian.Uint16(header[10:12]), binary.LittleEndian.Uint16(header[12:14]), binary.LittleEndian.Uint32(header[16:20]), int(compressedSize), uint64(uncompressedSize), int(localOffset))
		}
		position = recordEnd
	}
	return nil, errors.New("压缩包中没有 ZipCrypto 加密文件")
}

func findZipEndHeader(archive []byte) (int, error) {
	if len(archive) < 22 {
		return 0, errors.New("文件不是有效 ZIP")
	}
	minimum := max(0, len(archive)-22-65535)
	for offset := len(archive) - 22; offset >= minimum; offset-- {
		if binary.LittleEndian.Uint32(archive[offset:offset+4]) != zipEndHeaderSignature {
			continue
		}
		commentLength := int(binary.LittleEndian.Uint16(archive[offset+20 : offset+22]))
		if offset+22+commentLength == len(archive) {
			return offset, nil
		}
	}
	return 0, errors.New("ZIP 结束记录不存在")
}

func parseEncryptedZipLocalEntry(archive, name []byte, flags, method, modifiedTime uint16, crc uint32, compressedSize int, uncompressedSize uint64, localOffset int) (*encryptedZipEntry, error) {
	if method != 0 && method != 8 {
		return nil, fmt.Errorf("暂不支持 ZIP 压缩方法 %d", method)
	}
	if compressedSize < 12 || localOffset < 0 || localOffset+30 > len(archive) {
		return nil, errors.New("ZIP 加密条目不完整")
	}
	header := archive[localOffset : localOffset+30]
	if binary.LittleEndian.Uint32(header[0:4]) != zipLocalHeaderSignature {
		return nil, errors.New("ZIP 本地条目签名无效")
	}
	nameLength := int(binary.LittleEndian.Uint16(header[26:28]))
	extraLength := int(binary.LittleEndian.Uint16(header[28:30]))
	dataOffset := localOffset + 30 + nameLength + extraLength
	dataEnd := dataOffset + compressedSize
	if dataOffset < 0 || dataEnd < dataOffset || dataEnd > len(archive) {
		return nil, errors.New("ZIP 加密数据不完整")
	}
	checkByte := byte(crc >> 24)
	if flags&8 != 0 {
		checkByte = byte(modifiedTime >> 8)
	}
	return &encryptedZipEntry{name: append([]byte(nil), name...), flags: flags, method: method, crc: crc, uncompressedSize: uncompressedSize, encrypted: archive[dataOffset:dataEnd], checkByte: checkByte}, nil
}

func searchNumericZipPasswords(ctx context.Context, entry *encryptedZipEntry, workers int) (int, []byte, bool) {
	workers = max(1, min(workers, zipPasswordSpace))
	var next atomic.Uint64
	var stopped atomic.Bool
	result := make(chan struct {
		password int
		plain    []byte
	}, 1)
	var waitGroup sync.WaitGroup
	waitGroup.Add(workers)
	for worker := 0; worker < workers; worker++ {
		go func() {
			defer waitGroup.Done()
			for {
				if stopped.Load() || ctx.Err() != nil {
					return
				}
				chunkStart := int(next.Add(zipSearchChunkSize) - zipSearchChunkSize)
				if chunkStart >= zipPasswordSpace {
					return
				}
				chunkEnd := min(chunkStart+zipSearchChunkSize, zipPasswordSpace)
				for number := chunkStart; number < chunkEnd; number++ {
					if stopped.Load() || ctx.Err() != nil {
						return
					}
					var digits [6]byte
					value := number
					for index := len(digits) - 1; index >= 0; index-- {
						digits[index] = byte('0' + value%10)
						value /= 10
					}
					if plain, ok := decryptZipEntryWithPassword(entry, digits[:]); ok && stopped.CompareAndSwap(false, true) {
						result <- struct {
							password int
							plain    []byte
						}{number, plain}
						return
					}
				}
			}
		}()
	}
	waitGroup.Wait()
	close(result)
	match, found := <-result
	return match.password, match.plain, found
}

func decryptZipEntryWithPassword(entry *encryptedZipEntry, password []byte) ([]byte, bool) {
	keys := initializeZipKeys(password)
	var headerByte byte
	for _, encryptedByte := range entry.encrypted[:12] {
		headerByte = keys.decrypt(encryptedByte)
	}
	if headerByte != entry.checkByte {
		return nil, false
	}
	payload := make([]byte, len(entry.encrypted)-12)
	for index, encryptedByte := range entry.encrypted[12:] {
		payload[index] = keys.decrypt(encryptedByte)
	}
	if entry.method == 0 {
		if uint64(len(payload)) != entry.uncompressedSize || crc32.ChecksumIEEE(payload) != entry.crc {
			return nil, false
		}
		return payload, true
	}
	reader := flate.NewReader(bytes.NewReader(payload))
	plain, err := io.ReadAll(io.LimitReader(reader, maxImportFileBytes+1))
	closeErr := reader.Close()
	if err != nil || closeErr != nil || uint64(len(plain)) != entry.uncompressedSize || crc32.ChecksumIEEE(plain) != entry.crc {
		return nil, false
	}
	return plain, true
}

func initializeZipKeys(password []byte) zipCryptoKeys {
	keys := zipCryptoKeys{key0: 0x12345678, key1: 0x23456789, key2: 0x34567890}
	for _, value := range password {
		keys.update(value)
	}
	return keys
}

func (keys *zipCryptoKeys) update(value byte) {
	keys.key0 = zipCRC32Byte(keys.key0, value)
	keys.key1 = (keys.key1+(keys.key0&0xff))*134775813 + 1
	keys.key2 = zipCRC32Byte(keys.key2, byte(keys.key1>>24))
}

func (keys *zipCryptoKeys) decrypt(encrypted byte) byte {
	temporary := uint16(keys.key2 | 2)
	plain := encrypted ^ byte((uint32(temporary)*uint32(temporary^1))>>8)
	keys.update(plain)
	return plain
}

func zipCRC32Byte(crc uint32, value byte) uint32 {
	return (crc >> 8) ^ importZipCRCTable[byte(crc)^value]
}
