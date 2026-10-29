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
