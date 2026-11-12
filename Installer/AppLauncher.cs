using System;
using System.Collections.Generic;
using System.IO;
using System.Management.Automation;
using System.Management.Automation.Runspaces;
using System.Reflection;
using System.Threading;
using System.Windows.Forms;

[assembly: AssemblyTitle("Windows FPS Optimizer")]
[assembly: AssemblyVersion("__ASSEMBLY_VERSION__")]

namespace WindowsFPSOptimizer.Desktop
{
    internal static class Program
    {
        [STAThread]
        private static int Main(string[] args)
        {
            try
            {
                string root = Path.GetDirectoryName(Assembly.GetExecutingAssembly().Location);
                string script = Path.Combine(root, "WindowsFPSOptimizer.ps1");
                if (!File.Exists(script)) throw new FileNotFoundException("O aplicativo esta incompleto. Reinstale o Windows FPS Optimizer.");
                var switches = new HashSet<string>(StringComparer.OrdinalIgnoreCase) {
                    "Simulation", "NoSimulation", "ReadOnly", "Relaunched", "Advanced"
                };
                var values = new HashSet<string>(StringComparer.OrdinalIgnoreCase) {
                    "LaunchGameProfile", "ResumeAction", "ResumeDataBase64"
                };
                InitialSessionState initial = InitialSessionState.CreateDefault();
                initial.ExecutionPolicy = Microsoft.PowerShell.ExecutionPolicy.Bypass;
                using (Runspace runspace = RunspaceFactory.CreateRunspace(initial))
                {
                    runspace.ApartmentState = ApartmentState.STA;
                    runspace.ThreadOptions = PSThreadOptions.UseCurrentThread;
                    runspace.Open();
                    using (PowerShell engine = PowerShell.Create())
                    {
                        engine.Runspace = runspace;
                        engine.AddCommand(script);
                        for (int index = 0; index < args.Length; index++)
                        {
                            if (!args[index].StartsWith("-", StringComparison.Ordinal))
                                throw new ArgumentException("Argumento desconhecido.");
                            string name = args[index].TrimStart('-');
                            if (switches.Contains(name)) engine.AddParameter(name, true);
                            else if (values.Contains(name) && index + 1 < args.Length)
                                engine.AddParameter(name, args[++index]);
                            else throw new ArgumentException("Parametro invalido ou sem valor: " + name);
                        }
                        engine.Invoke();
                        if (engine.InvocationStateInfo.State == PSInvocationState.Failed)
                        {
                            string details = engine.InvocationStateInfo.Reason != null ? engine.InvocationStateInfo.Reason.Message : "Erro ao abrir a interface.";
                            throw new InvalidOperationException(details);
                        }
                    }
                }
                return 0;
            }
            catch (Exception error)
            {
                MessageBox.Show(error.Message, "Windows FPS Optimizer", MessageBoxButtons.OK, MessageBoxIcon.Error);
                return 1;
            }
        }
    }
}
