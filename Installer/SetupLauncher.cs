using System;
using System.Diagnostics;
using System.IO;
using System.IO.Compression;
using System.Reflection;
using System.Security.AccessControl;
using System.Security.Cryptography;
using System.Security.Principal;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Windows.Forms;
using Microsoft.Win32;

[assembly: AssemblyTitle("Windows FPS Optimizer Setup")]
[assembly: AssemblyDescription("Instalador offline do Windows FPS Optimizer")]
[assembly: AssemblyCompany("Windows FPS Optimizer")]
[assembly: AssemblyProduct("Windows FPS Optimizer")]
[assembly: AssemblyCopyright("Copyright (c) 2026")]
[assembly: AssemblyVersion("__ASSEMBLY_VERSION__")]
[assembly: AssemblyFileVersion("__ASSEMBLY_VERSION__")]
[assembly: AssemblyInformationalVersion("__APP_VERSION__")]

namespace WindowsFPSOptimizer.Setup
{
    internal static class Program
    {
        private const string AppName = "__APP_NAME__";
        private const string AppVersion = "__APP_VERSION__";
        private const string PayloadResource = "WindowsFPSOptimizer.Payload";
        private const string PayloadSha256 = "__PAYLOAD_SHA256__";

        [STAThread]
        private static int Main(string[] args)
        {
            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);

            string stagingDirectory = null;
            bool quiet = Array.Exists(args, delegate(string argument)
            {
                return String.Equals(argument, "/quiet", StringComparison.OrdinalIgnoreCase) ||
                    String.Equals(argument, "--quiet", StringComparison.OrdinalIgnoreCase);
            });
            try
            {
                foreach (string argument in args)
                {
                    if (!String.Equals(argument, "/quiet", StringComparison.OrdinalIgnoreCase) &&
                        !String.Equals(argument, "--quiet", StringComparison.OrdinalIgnoreCase))
                    {
                        throw new ArgumentException("Argumento desconhecido: " + argument);
                    }
                }
                if (!IsAdministrator())
                {
                    throw new InvalidOperationException(
                        "O instalador precisa de permissao administrativa. " +
                        "Confirme o UAC ao abrir o Setup.exe.");
                }

                string programFiles = GetNativeProgramFiles();
                if (String.IsNullOrWhiteSpace(programFiles))
                {
                    throw new InvalidOperationException("Program Files nao foi encontrado.");
                }

                programFiles = Path.GetFullPath(programFiles);
                string installRoot = Path.Combine(programFiles, "WindowsFPSOptimizer");
                EnsureNoReparsePoint(programFiles);
                EnsureNoReparsePoint(installRoot);

                Directory.CreateDirectory(installRoot);
                ProtectDirectory(installRoot);
                EnsureNoReparsePoint(installRoot);

                string session = Guid.NewGuid().ToString("N");
                stagingDirectory = Path.Combine(installRoot, ".installer-" + session);
                Directory.CreateDirectory(stagingDirectory);
                ProtectDirectory(stagingDirectory);
                EnsureSafeChild(installRoot, stagingDirectory);

                string payloadPath = Path.Combine(
                    stagingDirectory,
                    "WindowsFPSOptimizer-Payload.zip");
                ExtractPayload(payloadPath);
                ProtectFile(payloadPath);

                string extractedHash = ComputeSha256(payloadPath);
                if (!String.Equals(
                    extractedHash,
                    PayloadSha256,
                    StringComparison.OrdinalIgnoreCase))
                {
                    throw new InvalidDataException(
                        "O payload interno falhou na verificacao SHA-256.");
                }

                ExtractPackage(payloadPath, stagingDirectory);
                ProcessStartInfo startInfo = new ProcessStartInfo();
                startInfo.WorkingDirectory = stagingDirectory;
                startInfo.UseShellExecute = false;
                startInfo.CreateNoWindow = true;
                startInfo.WindowStyle = ProcessWindowStyle.Hidden;
                string windowsDirectory = Directory.GetParent(
                    Environment.SystemDirectory).FullName;
                string nativePowerShell = Path.Combine(
                    windowsDirectory,
                    Environment.Is64BitOperatingSystem ? "Sysnative" : "System32",
                    "WindowsPowerShell",
                    "v1.0",
                    "powershell.exe");
                if (!File.Exists(nativePowerShell))
                {
                    throw new FileNotFoundException(
                        "Windows PowerShell 5.1 nativo nao foi encontrado.",
                        nativePowerShell);
                }
                startInfo.EnvironmentVariables["TEMP"] = stagingDirectory;
                startInfo.EnvironmentVariables["TMP"] = stagingDirectory;
                startInfo.EnvironmentVariables["WINDIR"] = windowsDirectory;
                startInfo.EnvironmentVariables["SystemRoot"] = windowsDirectory;
                startInfo.FileName = nativePowerShell;
                startInfo.Arguments = "-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -STA -File \"" +
                    Path.Combine(stagingDirectory, "Install-WindowsFPSOptimizer.ps1") + "\" -NoLaunch -Quiet";
                startInfo.EnvironmentVariables["WFPO_INSTALL_SESSION"] = session;

                int innerExitCode;
                using (Process process = Process.Start(startInfo))
                {
                    if (process == null)
                    {
                        throw new InvalidOperationException(
                            "O processo interno do instalador nao foi iniciado.");
                    }
                    process.WaitForExit();
                    innerExitCode = process.ExitCode;
                }

                if (innerExitCode != 0)
                {
                    throw new InvalidOperationException(
                        "O instalador interno terminou com o codigo " +
                        innerExitCode.ToString() + ".");
                }

                string receiptPath = Path.Combine(
                    installRoot,
                    "InstallReceipts",
                    session + ".json");
                DateTime receiptDeadline = DateTime.UtcNow.AddSeconds(120);
                while (!File.Exists(receiptPath) && DateTime.UtcNow < receiptDeadline)
                {
                    Thread.Sleep(200);
                }
                if (!File.Exists(receiptPath))
                {
                    throw new InvalidOperationException(
                        "A instalacao nao confirmou o commit. Codigo interno: " +
                        innerExitCode.ToString());
                }

                string receiptText = File.ReadAllText(receiptPath, Encoding.UTF8);
                if (!Regex.IsMatch(
                    receiptText,
                    "\"Success\"\\s*:\\s*true",
                    RegexOptions.IgnoreCase))
                {
                    throw new InvalidDataException(
                        "O recibo da instalacao nao confirma sucesso.");
                }
                if (!Regex.IsMatch(
                    receiptText,
                    "\"Version\"\\s*:\\s*\"" + Regex.Escape(AppVersion) + "\"",
                    RegexOptions.IgnoreCase))
                {
                    throw new InvalidDataException(
                        "A versao do recibo nao corresponde ao pacote.");
                }
                if (!Regex.IsMatch(
                    receiptText,
                    "\"Session\"\\s*:\\s*\"" + Regex.Escape(session) + "\"",
                    RegexOptions.IgnoreCase))
                {
                    throw new InvalidDataException(
                        "A sessao do recibo nao corresponde ao launcher.");
                }

                string installedScript = Path.Combine(
                    installRoot,
                    "App",
                    AppVersion,
                    "WindowsFPSOptimizer.exe");
                EnsureSafeChild(installRoot, installedScript);
                if (!File.Exists(installedScript))
                {
                    throw new FileNotFoundException(
                        "O aplicativo grafico nao foi instalado.",
                        installedScript);
                }

                if (!quiet) MessageBox.Show(
                    AppName + " " + AppVersion +
                    " foi instalado com sucesso.\n\n" +
                    "Procure o atalho na Area de Trabalho ou no Menu Iniciar. " +
                    "Se ele nao estiver disponivel, execute:\n" +
                    installedScript + "\n\n" +
                    "O modo de simulacao permanece ativado por padrao.",
                    AppName,
                    MessageBoxButtons.OK,
                    MessageBoxIcon.Information);
                return 0;
            }
            catch (Exception exception)
            {
                if (quiet)
                {
                    Console.Error.WriteLine("Falha na instalacao: " + exception.Message);
                }
                else MessageBox.Show(
                    "O " + AppName + " nao foi instalado.\n\nDetalhes: " +
                    exception.Message,
                    "Falha na instalacao",
                    MessageBoxButtons.OK,
                    MessageBoxIcon.Error);
                return 1;
            }
            finally
            {
                if (!String.IsNullOrWhiteSpace(stagingDirectory))
                {
                    try
                    {
                        EnsureNoReparsePoint(stagingDirectory);
                        if (Directory.Exists(stagingDirectory))
                        {
                            Directory.Delete(stagingDirectory, true);
                        }
                    }
                    catch
                    {
                        // A instalacao ja terminou. Um arquivo bloqueado pode ser
                        // removido manualmente por um administrador mais tarde.
                    }
                }
            }
        }

        private static bool IsAdministrator()
        {
            WindowsIdentity identity = WindowsIdentity.GetCurrent();
            WindowsPrincipal principal = new WindowsPrincipal(identity);
            return principal.IsInRole(WindowsBuiltInRole.Administrator);
        }

        private static void ExtractPackage(string path, string directory)
        {
            using (ZipArchive archive = ZipFile.OpenRead(path))
            {
                if (archive.Entries.Count < 1 || archive.Entries.Count > 100)
                    throw new InvalidDataException("Pacote de instalacao invalido.");
                foreach (ZipArchiveEntry entry in archive.Entries)
                {
                    // O formato do pacote e plano: nenhuma subpasta, ADS ou link.
                    if (String.IsNullOrWhiteSpace(entry.FullName) || entry.FullName != entry.Name ||
                        entry.Name.IndexOfAny(new char[] { '/', '\\', ':' }) >= 0 ||
                        entry.Name == "." || entry.Name == ".." || entry.Length > 20 * 1024 * 1024)
                        throw new InvalidDataException("Nome ou tamanho de arquivo invalido no pacote.");
                    string destination = Path.GetFullPath(Path.Combine(directory, entry.Name));
                    EnsureSafeChild(directory, destination);
                    entry.ExtractToFile(destination, false);
                    ProtectFile(destination);
                }
            }
        }

        private static string GetNativeProgramFiles()
        {
            RegistryView view = Environment.Is64BitOperatingSystem
                ? RegistryView.Registry64
                : RegistryView.Registry32;
            using (RegistryKey localMachine = RegistryKey.OpenBaseKey(
                RegistryHive.LocalMachine,
                view))
            using (RegistryKey currentVersion = localMachine.OpenSubKey(
                @"SOFTWARE\Microsoft\Windows\CurrentVersion",
                false))
            {
                if (currentVersion == null)
                {
                    throw new InvalidOperationException(
                        "A configuracao ProgramFilesDir nao foi encontrada.");
                }
                string value = currentVersion.GetValue(
                    "ProgramFilesDir",
                    null,
                    RegistryValueOptions.DoNotExpandEnvironmentNames) as string;
                if (String.IsNullOrWhiteSpace(value))
                {
                    throw new InvalidOperationException(
                        "ProgramFilesDir esta vazio no Registro do Windows.");
                }
                if (value.IndexOf('%') >= 0)
                {
                    throw new InvalidOperationException(
                        "ProgramFilesDir contem variaveis de ambiente nao confiaveis.");
                }
                return Path.GetFullPath(value);
            }
        }

        private static void ExtractPayload(string destinationPath)
        {
            Assembly assembly = Assembly.GetExecutingAssembly();
            using (Stream resource = assembly.GetManifestResourceStream(PayloadResource))
            {
                if (resource == null)
                {
                    throw new InvalidDataException(
                        "O recurso interno do instalador nao foi encontrado.");
                }
                using (FileStream destination = new FileStream(
                    destinationPath,
                    FileMode.CreateNew,
                    FileAccess.Write,
                    FileShare.None))
                {
                    resource.CopyTo(destination);
                    destination.Flush(true);
                }
            }
        }

        private static string ComputeSha256(string path)
        {
            using (SHA256 sha = SHA256.Create())
            using (FileStream stream = new FileStream(
                path,
                FileMode.Open,
                FileAccess.Read,
                FileShare.Read))
            {
                return BitConverter.ToString(sha.ComputeHash(stream)).Replace("-", "");
            }
        }

        private static void EnsureSafeChild(string parentPath, string childPath)
        {
            string parent = Path.GetFullPath(parentPath).TrimEnd(
                Path.DirectorySeparatorChar,
                Path.AltDirectorySeparatorChar) + Path.DirectorySeparatorChar;
            string child = Path.GetFullPath(childPath);
            if (!child.StartsWith(parent, StringComparison.OrdinalIgnoreCase))
            {
                throw new InvalidOperationException(
                    "Um caminho saiu da raiz protegida do instalador.");
            }
            EnsureNoReparsePoint(parentPath);
            EnsureNoReparsePoint(childPath);
        }

        private static void EnsureNoReparsePoint(string path)
        {
            string fullPath = Path.GetFullPath(path);
            string root = Path.GetPathRoot(fullPath);
            string current = root;
            string relative = fullPath.Substring(root.Length);

            foreach (string segment in relative.Split(
                new char[] { Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar },
                StringSplitOptions.RemoveEmptyEntries))
            {
                current = Path.Combine(current, segment);
                if (Directory.Exists(current) || File.Exists(current))
                {
                    FileAttributes attributes = File.GetAttributes(current);
                    if ((attributes & FileAttributes.ReparsePoint) != 0)
                    {
                        throw new InvalidOperationException(
                            "Junction ou link simbolico recusado: " + current);
                    }
                }
            }
        }

        private static DirectorySecurity CreateDirectorySecurity()
        {
            SecurityIdentifier administrators =
                new SecurityIdentifier(WellKnownSidType.BuiltinAdministratorsSid, null);
            SecurityIdentifier system =
                new SecurityIdentifier(WellKnownSidType.LocalSystemSid, null);
            SecurityIdentifier users =
                new SecurityIdentifier(WellKnownSidType.BuiltinUsersSid, null);
            InheritanceFlags inheritance =
                InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit;

            DirectorySecurity security = new DirectorySecurity();
            security.SetAccessRuleProtection(true, false);
            security.SetOwner(administrators);
            security.AddAccessRule(new FileSystemAccessRule(
                system,
                FileSystemRights.FullControl,
                inheritance,
                PropagationFlags.None,
                AccessControlType.Allow));
            security.AddAccessRule(new FileSystemAccessRule(
                administrators,
                FileSystemRights.FullControl,
                inheritance,
                PropagationFlags.None,
                AccessControlType.Allow));
            security.AddAccessRule(new FileSystemAccessRule(
                users,
                FileSystemRights.ReadAndExecute | FileSystemRights.Synchronize,
                inheritance,
                PropagationFlags.None,
                AccessControlType.Allow));
            return security;
        }

        private static FileSecurity CreateFileSecurity()
        {
            SecurityIdentifier administrators =
                new SecurityIdentifier(WellKnownSidType.BuiltinAdministratorsSid, null);
            SecurityIdentifier system =
                new SecurityIdentifier(WellKnownSidType.LocalSystemSid, null);
            SecurityIdentifier users =
                new SecurityIdentifier(WellKnownSidType.BuiltinUsersSid, null);

            FileSecurity security = new FileSecurity();
            security.SetAccessRuleProtection(true, false);
            security.SetOwner(administrators);
            security.AddAccessRule(new FileSystemAccessRule(
                system,
                FileSystemRights.FullControl,
                AccessControlType.Allow));
            security.AddAccessRule(new FileSystemAccessRule(
                administrators,
                FileSystemRights.FullControl,
                AccessControlType.Allow));
            security.AddAccessRule(new FileSystemAccessRule(
                users,
                FileSystemRights.ReadAndExecute | FileSystemRights.Synchronize,
                AccessControlType.Allow));
            return security;
        }

        private static void ProtectDirectory(string path)
        {
            DirectoryInfo directory = new DirectoryInfo(path);
            directory.SetAccessControl(CreateDirectorySecurity());
        }

        private static void ProtectFile(string path)
        {
            FileInfo file = new FileInfo(path);
            file.SetAccessControl(CreateFileSecurity());
        }
    }
}
