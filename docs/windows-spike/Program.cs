// Steps 4 and 7 of the Windows spike.
// Overwrite C:\spike\Caller\Program.cs with this.
// Remember to add <AllowUnsafeBlocks>true</AllowUnsafeBlocks> to Caller.csproj,
// and to copy every DLL from ..\ProbeFFI\.build\release\ next to the built exe.

using System.Runtime.InteropServices;

internal static partial class N
{
    [LibraryImport("ProbeFFI")]
    internal static partial IntPtr probe_hello(
        [MarshalAs(UnmanagedType.LPUTF8Str)] string name);

    [LibraryImport("ProbeFFI")]
    internal static partial void probe_free(IntPtr p);

    [LibraryImport("ProbeFFI")]
    internal static partial void probe_main_queue();
}

// --- Step 4: does a synchronous @_cdecl entry point work at all?
var p = N.probe_hello("windows");
Console.WriteLine(Marshal.PtrToStringUTF8(p));
N.probe_free(p);
Console.WriteLine("freed cleanly");

// --- Step 7: is libdispatch's main queue alive in a .NET-hosted Swift DLL?
// Expected: "returning from probe_main_queue" appears, "MAIN QUEUE RAN" does not.
Console.WriteLine("--- step 7: main queue ---");
N.probe_main_queue();
Console.WriteLine("--- if MAIN QUEUE RAN did not appear above, R4 is confirmed ---");
