//! `grpc_dc::Message` adapters for the generated streams/processor
//! messages (same bridge pattern as the echo demo).

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

