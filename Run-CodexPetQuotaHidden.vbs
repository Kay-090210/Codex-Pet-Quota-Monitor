Option Explicit

Dim shell, fileSystem, scriptDirectory, mainScript, powershellPath, commandLine
Set shell = CreateObject("WScript.Shell")
Set fileSystem = CreateObject("Scripting.FileSystemObject")

scriptDirectory = fileSystem.GetParentFolderName(WScript.ScriptFullName)
mainScript = fileSystem.BuildPath(scriptDirectory, "CodexPetQuota.ps1")
powershellPath = shell.ExpandEnvironmentStrings("%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe")

If Not fileSystem.FileExists(mainScript) Then
    WScript.Quit 1
End If

commandLine = QuoteArgument(powershellPath) & _
    " -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File " & QuoteArgument(mainScript)

' windowStyle=0 creates the PowerShell host hidden; waitOnReturn=False detaches it
' from the short-lived launcher, so a terminal window is not required afterward.
shell.Run commandLine, 0, False
WScript.Quit 0

Function QuoteArgument(ByVal value)
    QuoteArgument = Chr(34) & value & Chr(34)
End Function
