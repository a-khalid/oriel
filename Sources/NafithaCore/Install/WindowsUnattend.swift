import Foundation

/// Answers for a hands-off Windows 11 ARM64 setup.
public struct WindowsUnattendOptions: Codable, Sendable, Equatable {
    public var userName: String
    /// Empty means a local account without a password.
    public var password: String
    public var computerName: String
    /// Must match the language of the ISO, e.g. "en-US" or "ar-SA", or setup stops.
    public var setupLanguage: String
    /// Region and formats for the installed system, e.g. "ar-SA".
    public var userLocale: String
    /// Keyboard layouts, e.g. ["en-US", "ar-SA"].
    public var keyboardLayouts: [String]
    /// Edition name as listed in install.wim, e.g. "Windows 11 Pro".
    public var edition: String
    /// Skips the TPM, Secure Boot, RAM, CPU and storage checks. Required: Virtualization.framework has no TPM.
    public var bypassHardwareChecks: Bool
    /// Wipes disk 0 and partitions it without asking.
    public var partitionDiskAutomatically: Bool
    /// Runs pnputil at first logon on any attached drive that looks like the virtio-win ISO.
    public var installVirtIODrivers: Bool

    public init(
        userName: String,
        password: String = "",
        computerName: String = "NAFITHA-PC",
        setupLanguage: String = "en-US",
        userLocale: String = "en-US",
        keyboardLayouts: [String] = ["en-US"],
        edition: String = "Windows 11 Pro",
        bypassHardwareChecks: Bool = true,
        partitionDiskAutomatically: Bool = true,
        installVirtIODrivers: Bool = true
    ) {
        self.userName = userName
        self.password = password
        self.computerName = computerName
        self.setupLanguage = setupLanguage
        self.userLocale = userLocale
        self.keyboardLayouts = keyboardLayouts
        self.edition = edition
        self.bypassHardwareChecks = bypassHardwareChecks
        self.partitionDiskAutomatically = partitionDiskAutomatically
        self.installVirtIODrivers = installVirtIODrivers
    }

    /// Microsoft's public generic install keys. They select an edition; they do not activate Windows.
    static let genericInstallKeys = [
        "Windows 11 Pro": "VK7JG-NPHTM-C97JM-9MPGT-3V66T",
        "Windows 11 Home": "YTMG3-N6DKC-DKB77-7M9GH-8HVX7",
    ]
}

public enum WindowsUnattend {
    public static let fileName = "Autounattend.xml"

    public static func xml(for options: WindowsUnattendOptions) -> String {
        let arch = #"processorArchitecture="arm64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS""#
        let keyboards = escape(options.keyboardLayouts.isEmpty ? options.userLocale : options.keyboardLayouts.joined(separator: ";"))
        let user = escape(options.userName)

        var windowsPE: [String] = []
        windowsPE.append("""
                <component name="Microsoft-Windows-International-Core-WinPE" \(arch)>
                    <SetupUILanguage><UILanguage>\(escape(options.setupLanguage))</UILanguage></SetupUILanguage>
                    <InputLocale>\(keyboards)</InputLocale>
                    <SystemLocale>\(escape(options.setupLanguage))</SystemLocale>
                    <UILanguage>\(escape(options.setupLanguage))</UILanguage>
                    <UserLocale>\(escape(options.userLocale))</UserLocale>
                </component>
        """)

        var setup: [String] = []
        if options.bypassHardwareChecks {
            let checks = ["BypassTPMCheck", "BypassSecureBootCheck", "BypassRAMCheck", "BypassCPUCheck", "BypassStorageCheck"]
            let commands = checks.enumerated().map { index, check in
                """
                            <RunSynchronousCommand wcm:action="add">
                                <Order>\(index + 1)</Order>
                                <Path>reg add HKLM\\SYSTEM\\Setup\\LabConfig /v \(check) /t REG_DWORD /d 1 /f</Path>
                            </RunSynchronousCommand>
                """
            }
            setup.append("""
                    <RunSynchronous>
            \(commands.joined(separator: "\n"))
                    </RunSynchronous>
            """)
        }
        if options.partitionDiskAutomatically {
            // GPT layout: EFI system, MSR, Windows. NVMe disks enumerate before USB media, so disk 0 is the VM disk.
            setup.append("""
                    <DiskConfiguration>
                        <Disk wcm:action="add">
                            <DiskID>0</DiskID>
                            <WillWipeDisk>true</WillWipeDisk>
                            <CreatePartitions>
                                <CreatePartition wcm:action="add"><Order>1</Order><Type>EFI</Type><Size>260</Size></CreatePartition>
                                <CreatePartition wcm:action="add"><Order>2</Order><Type>MSR</Type><Size>16</Size></CreatePartition>
                                <CreatePartition wcm:action="add"><Order>3</Order><Type>Primary</Type><Extend>true</Extend></CreatePartition>
                            </CreatePartitions>
                            <ModifyPartitions>
                                <ModifyPartition wcm:action="add"><Order>1</Order><PartitionID>1</PartitionID><Format>FAT32</Format><Label>System</Label></ModifyPartition>
                                <ModifyPartition wcm:action="add"><Order>2</Order><PartitionID>3</PartitionID><Format>NTFS</Format><Label>Windows</Label><Letter>C</Letter></ModifyPartition>
                            </ModifyPartitions>
                        </Disk>
                    </DiskConfiguration>
                    <ImageInstall>
                        <OSImage>
                            <InstallTo><DiskID>0</DiskID><PartitionID>3</PartitionID></InstallTo>
                            <InstallFrom>
                                <MetaData wcm:action="add"><Key>/IMAGE/NAME</Key><Value>\(escape(options.edition))</Value></MetaData>
                            </InstallFrom>
                        </OSImage>
                    </ImageInstall>
            """)
        }
        let productKey = WindowsUnattendOptions.genericInstallKeys[options.edition].map {
            "<ProductKey><Key>\($0)</Key><WillShowUI>OnError</WillShowUI></ProductKey>"
        } ?? ""
        setup.append("""
                    <UserData>
                        <AcceptEula>true</AcceptEula>
                        \(productKey)
                    </UserData>
        """)
        windowsPE.append("""
                <component name="Microsoft-Windows-Setup" \(arch)>
        \(setup.joined(separator: "\n"))
                </component>
        """)

        var firstLogon: [String] = []
        if options.installVirtIODrivers {
            // The virtio-win ISO has a NetKVM folder at its root; pnputil skips drivers for other architectures.
            let command = #"cmd /c for %d in (D E F G H I J K L M N) do @if exist %d:\NetKVM pnputil /add-driver %d:\*.inf /subdirs /install"#
            firstLogon.append("""
                        <SynchronousCommand wcm:action="add">
                            <Order>1</Order>
                            <CommandLine>\(escape(command))</CommandLine>
                            <Description>Install VirtIO drivers</Description>
                        </SynchronousCommand>
            """)
        }

        return """
        <?xml version="1.0" encoding="utf-8"?>
        <!-- Generated by Nafitha. -->
        <unattend xmlns="urn:schemas-microsoft-com:unattend" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
            <settings pass="windowsPE">
        \(windowsPE.joined(separator: "\n"))
            </settings>
            <settings pass="specialize">
                <component name="Microsoft-Windows-Shell-Setup" \(arch)>
                    <ComputerName>\(escape(options.computerName))</ComputerName>
                </component>
                <component name="Microsoft-Windows-Deployment" \(arch)>
                    <RunSynchronous>
                        <RunSynchronousCommand wcm:action="add">
                            <Order>1</Order>
                            <Path>reg add HKLM\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\OOBE /v BypassNRO /t REG_DWORD /d 1 /f</Path>
                        </RunSynchronousCommand>
                    </RunSynchronous>
                </component>
            </settings>
            <settings pass="oobeSystem">
                <component name="Microsoft-Windows-International-Core" \(arch)>
                    <InputLocale>\(keyboards)</InputLocale>
                    <SystemLocale>\(escape(options.userLocale))</SystemLocale>
                    <UILanguage>\(escape(options.setupLanguage))</UILanguage>
                    <UserLocale>\(escape(options.userLocale))</UserLocale>
                </component>
                <component name="Microsoft-Windows-Shell-Setup" \(arch)>
                    <OOBE>
                        <HideEULAPage>true</HideEULAPage>
                        <HideOEMRegistrationScreen>true</HideOEMRegistrationScreen>
                        <HideOnlineAccountScreens>true</HideOnlineAccountScreens>
                        <HideWirelessSetupInOOBE>true</HideWirelessSetupInOOBE>
                        <ProtectYourPC>3</ProtectYourPC>
                    </OOBE>
                    <UserAccounts>
                        <LocalAccounts>
                            <LocalAccount wcm:action="add">
                                <Name>\(user)</Name>
                                <DisplayName>\(user)</DisplayName>
                                <Group>Administrators</Group>
                                <Password>
                                    <Value>\(encodedPassword(options.password))</Value>
                                    <PlainText>false</PlainText>
                                </Password>
                            </LocalAccount>
                        </LocalAccounts>
                    </UserAccounts>
                    <AutoLogon>
                        <Enabled>true</Enabled>
                        <LogonCount>1</LogonCount>
                        <Username>\(user)</Username>
                        <Password>
                            <Value>\(encodedPassword(options.password))</Value>
                            <PlainText>false</PlainText>
                        </Password>
                    </AutoLogon>
                    <FirstLogonCommands>
        \(firstLogon.joined(separator: "\n"))
                    </FirstLogonCommands>
                </component>
            </settings>
        </unattend>

        """
    }

    /// Windows' "hidden" password format: Base64 of UTF-16LE(password + "Password").
    /// This is obfuscation, not encryption; the answer file still reveals the password.
    static func encodedPassword(_ password: String) -> String {
        var data = Data()
        for unit in (password + "Password").utf16 {
            data.append(UInt8(unit & 0xFF))
            data.append(UInt8(unit >> 8))
        }
        return data.base64EncodedString()
    }

    static func escape(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
}
