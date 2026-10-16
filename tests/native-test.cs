using System;
using System.Runtime.InteropServices;
public static class TestNative {
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hwnd);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hwnd,int cmd);
    [DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hwnd,IntPtr processId);
    [DllImport("user32.dll")] public static extern bool AttachThreadInput(uint from,uint to,bool attach);
    [DllImport("user32.dll")] public static extern IntPtr SetFocus(IntPtr hwnd);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern IntPtr FindWindow(string cls, string title);
    [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr hwnd,uint msg,IntPtr w,IntPtr l);
    [DllImport("user32.dll")] public static extern IntPtr SendMessage(IntPtr hwnd,uint msg,IntPtr w,IntPtr l);
    [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr value);
    [DllImport("user32.dll")] public static extern uint GetClipboardSequenceNumber();
    [DllImport("user32.dll")] public static extern uint SendInput(uint count, INPUT[] inputs, int size);
    [StructLayout(LayoutKind.Sequential)] public struct INPUT { public uint type; public UNION data; }
    [StructLayout(LayoutKind.Explicit)] public struct UNION { [FieldOffset(0)] public KEYBOARD keyboard; [FieldOffset(0)] public MOUSE mouse; }
    [StructLayout(LayoutKind.Sequential)] public struct KEYBOARD { public ushort vk,scan; public uint flags,time; public UIntPtr extra; }
    [StructLayout(LayoutKind.Sequential)] public struct MOUSE { public int x,y; public uint data,flags,time; public UIntPtr extra; }
    public static void Hotkey(ushort key) {
        ushort[] keys = {0x11,0x12,key,key,0x12,0x11};
        INPUT[] input = new INPUT[6];
        for (int i=0;i<6;i++) { input[i].type=1; input[i].data.keyboard.vk=keys[i]; input[i].data.keyboard.flags=i<3?0u:2u; }
        if (SendInput(6,input,Marshal.SizeOf(typeof(INPUT))) != 6) throw new Exception("SendInput failed");
    }
    public static void FocusFixture(IntPtr form, IntPtr textBox) {
        uint current = GetCurrentThreadId();
        uint foreground = GetWindowThreadProcessId(GetForegroundWindow(),IntPtr.Zero);
        uint target = GetWindowThreadProcessId(form,IntPtr.Zero);
        AttachThreadInput(current,foreground,true);
        AttachThreadInput(current,target,true);
        try { SetForegroundWindow(form); SetFocus(textBox); }
        finally { AttachThreadInput(current,target,false); AttachThreadInput(current,foreground,false); }
        if (GetForegroundWindow() != form) throw new Exception("Could not focus the test fixture");
    }
}