using System;
using System.Drawing;
using System.Runtime.InteropServices;

public static class SpeedEvidence {
    [DllImport("user32.dll")] public static extern IntPtr GetDlgItem(IntPtr window,int id);
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr window,out RECT rect);
    [DllImport("user32.dll")] static extern bool PrintWindow(IntPtr window,IntPtr dc,uint flags);
    [StructLayout(LayoutKind.Sequential)] struct RECT { public int left,top,right,bottom; }
    public static void Capture(IntPtr window,string path) {
        RECT rect;
        if (!GetWindowRect(window,out rect)) throw new Exception("Cannot measure speed window");
        using (var bitmap = new Bitmap(rect.right-rect.left,rect.bottom-rect.top)) {
            using (var graphics = Graphics.FromImage(bitmap)) {
                IntPtr dc = graphics.GetHdc();
                bool success;
                try { success = PrintWindow(window,dc,2); }
                finally { graphics.ReleaseHdc(dc); }
                if (!success) throw new Exception("Cannot capture speed window");
            }
            bitmap.Save(path,System.Drawing.Imaging.ImageFormat.Png);
        }
    }
}
