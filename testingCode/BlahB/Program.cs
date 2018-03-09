using System;
using System.Threading;

namespace BlahB
{
    class Program
    {
        static void Main(string[] args)
        {
            for (var i = 0; i < 30; i++) {
                Console.WriteLine($"Hello World! {i}");
                Thread.Sleep(1000);
            }
        }
    }
}
