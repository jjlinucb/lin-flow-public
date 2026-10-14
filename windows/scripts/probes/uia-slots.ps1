# uia-slots.ps1: prints the ids and vtable slots of UI Automation's COM interfaces, read out of
# the type library inside UIAutomationCore.dll. LinFlow.Engine/FieldReader.cs calls UI
# Automation straight through its vtables, and every number in it came from this. Run it again
# before adding a call there, and pass the interfaces to list:
#
#   powershell -NoProfile -File scripts\probes\uia-slots.ps1 -Names IUIAutomation,IUIAutomationElement
#
# With no names it lists every interface, about 120 of them. Slots 0 to 2 are IUnknown's.
# It reads the type library only; it creates no UI Automation object and touches no window.
param([string[]]$Names = @())
$src = @"
using System;
using System.Runtime.InteropServices;
using CT = System.Runtime.InteropServices.ComTypes;
public static class UiaTypeLib {
  [DllImport("oleaut32.dll", CharSet=CharSet.Unicode, PreserveSig=false)]
  static extern void LoadTypeLibEx(string file, int regkind, out CT.ITypeLib tlib);
  public static string Dump(string file, string[] names) {
    CT.ITypeLib tl; LoadTypeLibEx(file, 2, out tl);
    var sb = new System.Text.StringBuilder();
    for (int i = 0; i < tl.GetTypeInfoCount(); i++) {
      string name, doc, help; int ctx;
      tl.GetDocumentation(i, out name, out doc, out ctx, out help);
      if (names.Length > 0 && Array.IndexOf(names, name) < 0) continue;
      CT.ITypeInfo ti; tl.GetTypeInfo(i, out ti);
      IntPtr pa; ti.GetTypeAttr(out pa);
      var ta = (CT.TYPEATTR)Marshal.PtrToStructure(pa, typeof(CT.TYPEATTR));
      sb.AppendLine(name + " {" + ta.guid + "} " + ta.typekind);
      for (int f = 0; f < ta.cFuncs; f++) {
        IntPtr pf; ti.GetFuncDesc(f, out pf);
        var fd = (CT.FUNCDESC)Marshal.PtrToStructure(pf, typeof(CT.FUNCDESC));
        string[] pn = new string[fd.cParams + 1]; int got;
        ti.GetNames(fd.memid, pn, pn.Length, out got);
        sb.AppendLine("  slot " + (fd.oVft / IntPtr.Size) + " " + pn[0] + " " + fd.invkind
          + " (" + string.Join(",", pn, 1, Math.Max(0, got - 1)) + ")");
        ti.ReleaseFuncDesc(pf);
      }
      ti.ReleaseTypeAttr(pa);
    }
    return sb.ToString();
  }
}
"@
Add-Type -TypeDefinition $src
[UiaTypeLib]::Dump("$env:SystemRoot\System32\UIAutomationCore.dll", $Names) | Out-String -Width 300
