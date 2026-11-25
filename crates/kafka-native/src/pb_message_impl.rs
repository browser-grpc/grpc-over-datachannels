//! `grpc_dc::Message` adapters for the generated kafka
//! messages (same bridge pattern as the echo demo).

macro_rules! kafka_msg {
    ($t:ident) => {
        impl grpc_dc::Message for crate::pb::$t {
            fn encode(&self) -> Vec<u8> {
                crate::pb::$t::encode(self)
            }
            fn decode(bytes: &[u8]) -> Result<Self, grpc_dc::Status> {
                crate::pb::$t::decode(bytes).map_err(grpc_dc::Status::invalid_argument)
            }
        }
    };
}

kafka_msg!(Header);
kafka_msg!(Record);
kafka_msg!(FetchedRecord);
kafka_msg!(TopicPartition);
kafka_msg!(MetadataRequest);
kafka_msg!(BrokerMetadata);
kafka_msg!(PartitionMetadata);
kafka_msg!(TopicMetadata);
kafka_msg!(MetadataResponse);
kafka_msg!(OpenProducerRequest);
kafka_msg!(OpenProducerResponse);
kafka_msg!(CloseProducerRequest);
kafka_msg!(CloseProducerResponse);
kafka_msg!(EndTransactionRequest);
kafka_msg!(EndTransactionResponse);
kafka_msg!(ProduceRequest);
kafka_msg!(ProduceResponse);
kafka_msg!(ConsumeRequest);
kafka_msg!(ConsumeResponse);
kafka_msg!(GroupSubscribeRequest);
kafka_msg!(GroupSubscribeResponse);
kafka_msg!(Assignment);
kafka_msg!(RecordBatch);
kafka_msg!(GroupError);
kafka_msg!(ListOffsetsRequest);
kafka_msg!(ListOffsetsResponse);
kafka_msg!(CommitOffsetRequest);
kafka_msg!(CommitOffsetResponse);
kafka_msg!(FetchOffsetRequest);
kafka_msg!(FetchOffsetResponse);
kafka_msg!(NewTopic);
kafka_msg!(CreateTopicsRequest);
kafka_msg!(TopicError);
kafka_msg!(CreateTopicsResponse);
kafka_msg!(DeleteTopicsRequest);
kafka_msg!(DeleteTopicsResponse);
kafka_msg!(ConfigEntry);
kafka_msg!(AlterConfigEntry);
kafka_msg!(DescribeConfigsRequest);
kafka_msg!(ConfigValue);
kafka_msg!(DescribeConfigsResponse);
kafka_msg!(AlterConfigsRequest);
kafka_msg!(AlterConfigsResponse);
kafka_msg!(CreatePartitionsRequest);
kafka_msg!(CreatePartitionsResponse);
kafka_msg!(DeleteRecordsRequest);
kafka_msg!(DeleteRecordsResponse);
kafka_msg!(ListGroupsRequest);
kafka_msg!(GroupListing);
kafka_msg!(ListGroupsResponse);
kafka_msg!(DescribeGroupsRequest);
kafka_msg!(GroupMember);
kafka_msg!(DescribedGroup);
kafka_msg!(DescribeGroupsResponse);
kafka_msg!(DeleteGroupsRequest);
kafka_msg!(GroupErrorResult);
kafka_msg!(DeleteGroupsResponse);
kafka_msg!(DeleteGroupOffsetsRequest);
kafka_msg!(DeleteGroupOffsetsResponse);
kafka_msg!(Acl);
kafka_msg!(DescribeAclsRequest);
kafka_msg!(DescribeAclsResponse);
kafka_msg!(CreateAclsRequest);
kafka_msg!(CreateAclsResponse);
kafka_msg!(DeleteAclsRequest);
kafka_msg!(DeleteAclsResponse);
kafka_msg!(ListTransactionsRequest);
kafka_msg!(TransactionListing);
kafka_msg!(ListTransactionsResponse);
kafka_msg!(DescribeTransactionsRequest);
kafka_msg!(DescribedTransaction);
kafka_msg!(DescribeTransactionsResponse);
kafka_msg!(OpenShareGroupRequest);
kafka_msg!(OpenShareGroupResponse);
kafka_msg!(SharePollRequest);
kafka_msg!(SharePollRecord);
kafka_msg!(SharePollResponse);
kafka_msg!(ShareAckEntry);
kafka_msg!(ShareAckRequest);
kafka_msg!(ShareAckResponse);
kafka_msg!(CloseShareGroupRequest);
kafka_msg!(CloseShareGroupResponse);
kafka_msg!(ShareGroupMember);
kafka_msg!(ShareGroupDescription);
kafka_msg!(DescribeShareGroupsRequest);
kafka_msg!(DescribeShareGroupsResponse);

macro_rules! streams_msg {
    ($t:ident) => {
        impl grpc_dc::Message for crate::streams_pb::$t {
            fn encode(&self) -> Vec<u8> {
                crate::streams_pb::$t::encode(self)
            }
            fn decode(bytes: &[u8]) -> Result<Self, grpc_dc::Status> {
                crate::streams_pb::$t::decode(bytes).map_err(grpc_dc::Status::invalid_argument)
            }
        }
    };
}

streams_msg!(Topology);
streams_msg!(TopologyInfo);
streams_msg!(CreateTopologyRequest);
streams_msg!(DescribeTopologyRequest);
streams_msg!(ListTopologiesRequest);
streams_msg!(ListTopologiesResponse);
streams_msg!(DeleteTopologyRequest);
streams_msg!(DeleteTopologyResponse);
streams_msg!(GetStoreValueRequest);
streams_msg!(GetStoreValueResponse);

streams_msg!(Step);

macro_rules! processor_msg {
    ($t:ident) => {
        impl grpc_dc::Message for crate::processor_pb::$t {
            fn encode(&self) -> Vec<u8> {
                crate::processor_pb::$t::encode(self)
            }
            fn decode(bytes: &[u8]) -> Result<Self, grpc_dc::Status> {
                crate::processor_pb::$t::decode(bytes).map_err(grpc_dc::Status::invalid_argument)
            }
        }
    };
}

processor_msg!(ProcessRecord);
processor_msg!(OutRecord);
processor_msg!(ProcessResult);
processor_msg!(GetStateRequest);
processor_msg!(GetStateResponse);
processor_msg!(PutStateRequest);
processor_msg!(PutStateResponse);
streams_msg!(StoreEntry);
streams_msg!(FetchRangeRequest);
streams_msg!(FetchRangeResponse);
streams_msg!(FetchWindowRangeRequest);
streams_msg!(FetchWindowRangeResponse);
streams_msg!(FetchWindowRequest);
streams_msg!(FetchWindowResponse);

