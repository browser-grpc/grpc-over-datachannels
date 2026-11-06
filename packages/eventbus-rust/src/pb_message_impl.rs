// grpc_dc::Message adapters for the events messages (same
// macro bridge the in-repo eventbus tests use).
use crate::events_pb::{Event, PublishReply, PublishRequest, SubscribeRequest, TagValue};
use grpc_dc::Message;

macro_rules! impl_message {
    ($t:ty) => {
        impl Message for $t {
            fn encode(&self) -> Vec<u8> { <$t>::encode(self) }
            fn decode(bytes: &[u8]) -> Result<Self, grpc_dc::Status> {
                <$t>::decode(bytes).map_err(grpc_dc::Status::invalid_argument)
            }
        }
    };
}
impl_message!(TagValue);
impl_message!(PublishRequest);
impl_message!(PublishReply);
impl_message!(SubscribeRequest);
impl_message!(Event);
