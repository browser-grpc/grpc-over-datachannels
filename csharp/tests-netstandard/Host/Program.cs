using System;

namespace NetstandardHost
{
    internal static class Program
    {
        private static int Main()
        {
            try
            {
                string summary = Consumer.ConsumerSmoke.Run();
                string kafkaAssembly = Consumer.KafkaUse.Check();
                if (kafkaAssembly != "KafkaGrpc")
                {
                    throw new Exception("kafka types resolved from " + kafkaAssembly + ", expected KafkaGrpc");
                }
                Console.WriteLine("CONSUMER_SMOKE_OK " + summary + " kafka@" + kafkaAssembly);
                return 0;
            }
            catch (Exception e)
            {
                Console.WriteLine("CONSUMER_SMOKE_FAIL " + e);
                return 1;
            }
        }
    }
}
