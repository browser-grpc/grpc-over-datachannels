// Kafka native client for Go (cgo, native only).
//
// The collapsed form of the Kafka proxy: the Kafka protocol
// implementation runs in this process through the
// kafka-native shared library (C ABI via cgo), instead of
// in a kafka_proxy sidecar reached over gRPC. Method
// surface mirrors the generated KafkaClient; requests and
// responses are the same generated message types.
//
// Behind the kafka_native build tag so default builds stay
// cgo-free:
//
//	CGO_LDFLAGS="-L<lib dir> -Wl,-rpath,<lib dir>" \
//	  go test -tags kafka_native ./...
//
//go:build kafka_native

package v1

/*
#cgo CFLAGS: -I${SRCDIR}/../../crates/kafka-native/include
#cgo LDFLAGS: -lkafka_native

#include "kafka_native.h"
#include <stdlib.h>
*/
import "C"

import (
	"errors"
	"fmt"
	"unsafe"
)

type dcMarshaler interface{ MarshalDC() []byte }
type dcUnmarshaler interface{ UnmarshalDC([]byte) error }

// KafkaNativeClient is the in-process native client.
type KafkaNativeClient struct {
	handle *C.KafkaNativeHandle
}

// NewKafkaNativeClient connects a native client to broker
// ("host:port").
func NewKafkaNativeClient(broker string) (*KafkaNativeClient, error) {
	b := C.CString(broker)
	defer C.free(unsafe.Pointer(b))
	cid := C.CString("grpc-dc-kafka-native")
	defer C.free(unsafe.Pointer(cid))
	h := C.kafka_native_new(b, cid)
	if h == nil {
		return nil, fmt.Errorf("kafka-native: %s", lastError())
	}
	return &KafkaNativeClient{handle: h}, nil
}

func lastError() string {
	return C.GoString(C.kafka_native_last_error())
}

// Close frees the native handle.
func (c *KafkaNativeClient) Close() {
	if c.handle != nil {
		C.kafka_native_free(c.handle)
		c.handle = nil
	}
}

func (c *KafkaNativeClient) call(method string, req dcMarshaler, resp dcUnmarshaler) error {
	payload := req.MarshalDC()
	m := C.CString(method)
	defer C.free(unsafe.Pointer(m))
	var buf unsafe.Pointer
	if len(payload) > 0 {
		buf = C.CBytes(payload)
		defer C.free(buf)
	}
	var out *C.uint8_t
	var outLen C.size_t
	rc := C.kafka_native_call(c.handle, m, (*C.uint8_t)(buf), C.size_t(len(payload)), &out, &outLen)
	if rc != 0 {
		return fmt.Errorf("kafka-native %s: %s", method, lastError())
	}
	var data []byte
	if out != nil && outLen > 0 {
		data = C.GoBytes(unsafe.Pointer(out), C.int(outLen))
		C.kafka_native_bytes_free(out, outLen)
	}
	return resp.UnmarshalDC(data)
}

// KafkaNativeStream is a Consume/Subscribe chunk stream.
type KafkaNativeStream[T any] struct {
	stream *C.KafkaNativeStream
	make   func() (T, dcUnmarshaler)
	closed bool
}

func streamNew[T any](c *KafkaNativeClient, method string, req dcMarshaler, make func() (T, dcUnmarshaler)) (*KafkaNativeStream[T], error) {
	payload := req.MarshalDC()
	m := C.CString(method)
	defer C.free(unsafe.Pointer(m))
	var buf unsafe.Pointer
	if len(payload) > 0 {
		buf = C.CBytes(payload)
		defer C.free(buf)
	}
	s := C.kafka_native_stream_new(c.handle, m, (*C.uint8_t)(buf), C.size_t(len(payload)))
	if s == nil {
		return nil, fmt.Errorf("kafka-native %s: %s", method, lastError())
	}
	return &KafkaNativeStream[T]{stream: s, make: make}, nil
}

// Next returns the next chunk, or ok=false at end of stream.
func (s *KafkaNativeStream[T]) Next() (T, bool, error) {
	var zero T
	if s.closed {
		return zero, false, nil
	}
	var out *C.uint8_t
	var outLen C.size_t
	rc := C.kafka_native_stream_next(s.stream, &out, &outLen)
	if rc == 0 {
		return zero, false, nil
	}
	if rc < 0 {
		return zero, false, fmt.Errorf("kafka-native stream: %s", lastError())
	}
	resp, unmarshaler := s.make()
	if out != nil && outLen > 0 {
		data := C.GoBytes(unsafe.Pointer(out), C.int(outLen))
		C.kafka_native_bytes_free(out, outLen)
		if err := unmarshaler.UnmarshalDC(data); err != nil {
			return zero, false, err
		}
	}
	return resp, true, nil
}

// Close frees the native stream.
func (s *KafkaNativeStream[T]) Close() {
	if !s.closed && s.stream != nil {
		C.kafka_native_stream_free(s.stream)
		s.closed = true
	}
}

var errClosed = errors.New("kafka-native: client closed")

func (c *KafkaNativeClient) unary(method string, req dcMarshaler, resp dcUnmarshaler) error {
	if c.handle == nil {
		return errClosed
	}
	return c.call(method, req, resp)
}

func (c *KafkaNativeClient) Metadata(req *MetadataRequest) (*MetadataResponse, error) {
	resp := &MetadataResponse{}
	return resp, c.unary("Metadata", req, resp)
}

func (c *KafkaNativeClient) OpenProducer(req *OpenProducerRequest) (*OpenProducerResponse, error) {
	resp := &OpenProducerResponse{}
	return resp, c.unary("OpenProducer", req, resp)
}

func (c *KafkaNativeClient) CloseProducer(req *CloseProducerRequest) (*CloseProducerResponse, error) {
	resp := &CloseProducerResponse{}
	return resp, c.unary("CloseProducer", req, resp)
}

func (c *KafkaNativeClient) EndTransaction(req *EndTransactionRequest) (*EndTransactionResponse, error) {
	resp := &EndTransactionResponse{}
	return resp, c.unary("EndTransaction", req, resp)
}

func (c *KafkaNativeClient) Produce(req *ProduceRequest) (*ProduceResponse, error) {
	resp := &ProduceResponse{}
	return resp, c.unary("Produce", req, resp)
}

func (c *KafkaNativeClient) Consume(req *ConsumeRequest) (*KafkaNativeStream[*ConsumeResponse], error) {
	return streamNew(c, "Consume", req, func() (*ConsumeResponse, dcUnmarshaler) {
		r := &ConsumeResponse{}
		return r, r
	})
}

func (c *KafkaNativeClient) Subscribe(req *GroupSubscribeRequest) (*KafkaNativeStream[*GroupSubscribeResponse], error) {
	return streamNew(c, "Subscribe", req, func() (*GroupSubscribeResponse, dcUnmarshaler) {
		r := &GroupSubscribeResponse{}
		return r, r
	})
}

func (c *KafkaNativeClient) ListOffsets(req *ListOffsetsRequest) (*ListOffsetsResponse, error) {
	resp := &ListOffsetsResponse{}
	return resp, c.unary("ListOffsets", req, resp)
}

func (c *KafkaNativeClient) CommitOffset(req *CommitOffsetRequest) (*CommitOffsetResponse, error) {
	resp := &CommitOffsetResponse{}
	return resp, c.unary("CommitOffset", req, resp)
}

func (c *KafkaNativeClient) FetchOffset(req *FetchOffsetRequest) (*FetchOffsetResponse, error) {
	resp := &FetchOffsetResponse{}
	return resp, c.unary("FetchOffset", req, resp)
}

func (c *KafkaNativeClient) CreateTopics(req *CreateTopicsRequest) (*CreateTopicsResponse, error) {
	resp := &CreateTopicsResponse{}
	return resp, c.unary("CreateTopics", req, resp)
}

func (c *KafkaNativeClient) DeleteTopics(req *DeleteTopicsRequest) (*DeleteTopicsResponse, error) {
	resp := &DeleteTopicsResponse{}
	return resp, c.unary("DeleteTopics", req, resp)
}

func (c *KafkaNativeClient) DescribeConfigs(req *DescribeConfigsRequest) (*DescribeConfigsResponse, error) {
	resp := &DescribeConfigsResponse{}
	return resp, c.unary("DescribeConfigs", req, resp)
}

func (c *KafkaNativeClient) AlterConfigs(req *AlterConfigsRequest) (*AlterConfigsResponse, error) {
	resp := &AlterConfigsResponse{}
	return resp, c.unary("AlterConfigs", req, resp)
}

func (c *KafkaNativeClient) CreatePartitions(req *CreatePartitionsRequest) (*CreatePartitionsResponse, error) {
	resp := &CreatePartitionsResponse{}
	return resp, c.unary("CreatePartitions", req, resp)
}

func (c *KafkaNativeClient) DeleteRecords(req *DeleteRecordsRequest) (*DeleteRecordsResponse, error) {
	resp := &DeleteRecordsResponse{}
	return resp, c.unary("DeleteRecords", req, resp)
}

func (c *KafkaNativeClient) ListGroups(req *ListGroupsRequest) (*ListGroupsResponse, error) {
	resp := &ListGroupsResponse{}
	return resp, c.unary("ListGroups", req, resp)
}

func (c *KafkaNativeClient) DescribeGroups(req *DescribeGroupsRequest) (*DescribeGroupsResponse, error) {
	resp := &DescribeGroupsResponse{}
	return resp, c.unary("DescribeGroups", req, resp)
}

func (c *KafkaNativeClient) DeleteGroups(req *DeleteGroupsRequest) (*DeleteGroupsResponse, error) {
	resp := &DeleteGroupsResponse{}
	return resp, c.unary("DeleteGroups", req, resp)
}

func (c *KafkaNativeClient) DeleteGroupOffsets(req *DeleteGroupOffsetsRequest) (*DeleteGroupOffsetsResponse, error) {
	resp := &DeleteGroupOffsetsResponse{}
	return resp, c.unary("DeleteGroupOffsets", req, resp)
}

func (c *KafkaNativeClient) DescribeAcls(req *DescribeAclsRequest) (*DescribeAclsResponse, error) {
	resp := &DescribeAclsResponse{}
	return resp, c.unary("DescribeAcls", req, resp)
}

func (c *KafkaNativeClient) CreateAcls(req *CreateAclsRequest) (*CreateAclsResponse, error) {
	resp := &CreateAclsResponse{}
	return resp, c.unary("CreateAcls", req, resp)
}

func (c *KafkaNativeClient) DeleteAcls(req *DeleteAclsRequest) (*DeleteAclsResponse, error) {
	resp := &DeleteAclsResponse{}
	return resp, c.unary("DeleteAcls", req, resp)
}

func (c *KafkaNativeClient) ListTransactions(req *ListTransactionsRequest) (*ListTransactionsResponse, error) {
	resp := &ListTransactionsResponse{}
	return resp, c.unary("ListTransactions", req, resp)
}

func (c *KafkaNativeClient) DescribeTransactions(req *DescribeTransactionsRequest) (*DescribeTransactionsResponse, error) {
	resp := &DescribeTransactionsResponse{}
	return resp, c.unary("DescribeTransactions", req, resp)
}
