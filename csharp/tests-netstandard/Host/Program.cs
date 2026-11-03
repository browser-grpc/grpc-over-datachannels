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
                Console.WriteLine("CONSUMER_SMOKE_OK " + summary);
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
