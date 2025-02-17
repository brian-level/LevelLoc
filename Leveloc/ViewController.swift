//
//  ViewController.swift
//  Leveloc
//
//  Created by Brian Dodge on 2/17/25.
//

import UIKit
import CoreBluetooth
import NearbyInteraction

let UWB_Service_CBUUID = CBUUID(string:"6E400001-B5A3-F393-E0A9-E50E24DCCA9E")
let UWB_Data_Tx_CBUUID = CBUUID(string:"6E400002-B5A3-F393-E0A9-E50E24DCCA9E")
let UWB_Data_RX_CBUUID = CBUUID(string:"6E400003-B5A3-F393-E0A9-E50E24DCCA9E")

// ARKit needs to be involved to get azimuth/elevation on phone
let hasAngles = false

enum MessageId: UInt8 {
    // Messages from the accessory.
    case accessoryConfigurationData = 0x1
    case accessoryUwbDidStart = 0x2
    case accessoryUwbDidStop = 0x3
    
    // Messages to the accessory.
    case initialize = 0xA
    case configureAndStart = 0xB
    case stop = 0xC
}

enum bleState {
    case Off
    case On
    case Searching
    case Selected
    case Connecting
    case Connected
    case Disconnecting
}

class ViewController:
    UIViewController,
    UITableViewDelegate,
    UITableViewDataSource,
    CBCentralManagerDelegate,
    CBPeripheralDelegate,
    NISessionDelegate,
    UITextFieldDelegate
{
    @IBOutlet weak var searchUUID: UILabel!
    @IBOutlet weak var connectButton: UIButton!
    @IBOutlet weak var deviceTable: UITableView!
    @IBOutlet weak var distanceDisplay: UILabel!
    @IBOutlet weak var azimSlider: UISlider!
    
    // MARK: Core Bluetooth
    var centralMan : CBCentralManager?
    var foundPeripheral : CBPeripheral?
    
    var state : bleState = bleState.Off
    
    // MARK: device table database
    var devices = [CBPeripheral]()
    var rssiTab = [Int]()
    var infoTab = [Data]()
    
    // MARK: peripheral services database
    var services = [CBService]()
    
    var rxChar : CBCharacteristic?
    var txChar : CBCharacteristic?

    // MARK: Nearby Interaction
    var niSession = NISession()
    var configuration: NINearbyAccessoryConfiguration?

    override func viewDidLoad() {
        super.viewDidLoad()
        // Do any additional setup after loading the view.
        searchUUID.text = UWB_Service_CBUUID.uuidString
        distanceDisplay.text = ""
        
        // start off in powered down state
        setState(bleState.Off)
        
        // setup delegate and datasource for table
        deviceTable.delegate = self
        deviceTable.dataSource = self
        
        // Creates a dispatch queue for concurrent central operations
        let centralQueue: DispatchQueue = DispatchQueue(label: "com.cci.blecentralq", attributes: .concurrent)
        // Create a core bluetooth central manager
        centralMan = CBCentralManager(delegate: self, queue: centralQueue)
     
        niSession.delegate = self
    }
    
    //MARK: State functions
    func setState(_ newState: bleState) {
        if newState == state {
            return
        }
        if state == bleState.Searching {
            centralMan?.stopScan()
        }
        state = newState
        print("New state: \(state)")
        
        switch state {
        case .Off:
            connectButton.isEnabled = false
        case .On:
            connectButton.setTitle("Connect", for: .normal);
            connectButton.isEnabled = false
            deviceTable.isUserInteractionEnabled = true
            setState(.Searching)
        case .Searching:
            deviceTable_clear()
            deviceTable.isUserInteractionEnabled = true
            print("Searching for UUID \(UWB_Service_CBUUID)")
            centralMan?.scanForPeripherals(withServices: [UWB_Service_CBUUID])
            connectButton.isEnabled = false
        case .Selected:
            deviceTable.isUserInteractionEnabled = true
            connectButton.isEnabled = true
        case .Connecting:
            if foundPeripheral != nil {
                foundPeripheral!.delegate = self
                deviceTable.isUserInteractionEnabled = false
                centralMan?.connect(foundPeripheral!)
            }
            connectButton.isEnabled = false
        case .Connected:
            connectButton.setTitle("Disconnect", for: .normal);
            connectButton.isEnabled = true
        case .Disconnecting:
            if foundPeripheral != nil {
                centralMan?.cancelPeripheralConnection(foundPeripheral!)
            }
            deviceTable.isUserInteractionEnabled = true
            connectButton.setTitle("Connect", for: .normal);
            connectButton.isEnabled = true
        }
    }
    
    //MARK: Device Table functions
    func deviceTable_clear() {
        devices.removeAll()
        deviceTable.reloadData()
    }
    
    //MARK: Device TableView functions
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return devices.count
    }
    
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "DeviceCell", for: indexPath)
        var rssiStr = "  "
        var devname : String
        
        let rssi = rssiTab[indexPath.row]
        rssiStr = String(format: "%4d ", rssi)
        
        devname = devices[indexPath.row].name ?? "<No Device Name>"
        
        cell.textLabel?.text = rssiStr + devname
        cell.detailTextLabel?.text = devices[indexPath.row].identifier.uuidString
        let infoData = infoTab[indexPath.row]
        if infoData.count >= 4 {
            // decode infoData:
            cell.detailTextLabel?.text = String(format:"(v%d.%d.%d) (%@) %@", infoData[0], infoData[1], infoData[2], (infoData[3] == 1) ? "OWNED" : "NEW", devices[indexPath.row].identifier.uuidString)
        }
        return cell
    }
    
    func tableView(_ tableView: UITableView, willSelectRowAt indexPath: IndexPath) -> IndexPath? {
        return indexPath
    }
    
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        foundPeripheral = devices[indexPath.row]
        setState(bleState.Selected)
    }
    
    func accessorySharedData(data: Data) {
        // The accessory begins each message with an identifier byte.
        // Ensure the message length is within a valid range.
        if data.count < 1 {
            print("Accessory shared data length was less than 1.")
            return
        }
        
        // Assign the first byte which is the message identifier.
        guard let messageId = MessageId(rawValue: data.first!) else {
            fatalError("\(data.first!) is not a valid MessageId.")
        }
        
        // Handle the data portion of the message based on the message identifier.
        switch messageId {
        case .accessoryConfigurationData:
            // Access the message data by skipping the message identifier.
            assert(data.count > 1)
            let message = data.advanced(by: 1)
            setupAccessory(message)
        case .accessoryUwbDidStart:
            handleAccessoryUwbDidStart()
        case .accessoryUwbDidStop:
            handleAccessoryUwbDidStop()
        case .configureAndStart:
            fatalError("Accessory should not send 'configureAndStart'.")
        case .initialize:
            fatalError("Accessory should not send 'initialize'.")
        case .stop:
            fatalError("Accessory should not send 'stop'.")
        }
    }
    
    func accessoryConnected(name: String) {
        //accessoryConnected = true
        //connectedAccessoryName = name
        print("Requesting configuration data from accessory \(name)")
        let msg = Data([MessageId.initialize.rawValue])
        sendDataToAccessory(msg)
    }
    
    func accessoryDisconnected() {
        //accessoryConnected = false
        //connectedAccessoryName = nil
        print("Accessory disconnected")
    }
    
    // MARK: - Accessory messages handling
    
    func setupAccessory(_ configData: Data) {
        print("Received configuration data. Running session.")
        do {
            configuration = try NINearbyAccessoryConfiguration(data: configData)
        } catch {
            // Stop and display the issue because the incoming data is invalid.
            // In your app, debug the accessory data to ensure an expected
            // format.
            print("Failed to create NINearbyAccessoryConfiguration. Error: \(error)")
            return
        }
        
        if hasAngles {
            configuration?.isCameraAssistanceEnabled = true
        }
        // Cache the token to correlate updates with this accessory.
        //cacheToken(configuration!.accessoryDiscoveryToken, accessoryName: name)
        niSession.run(configuration!)
    }
    
    func handleAccessoryUwbDidStart() {
        print("Accessory session started.")
    }
    
    func handleAccessoryUwbDidStop() {
        print("Accessory session stopped.")
    }

    //MARK: CBCentralManagerDelegate interface
    
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        
        switch central.state {
        case .unknown:
            print("Bluetooth status is UNKNOWN")
        case .resetting:
            print("Bluetooth status is RESETTING")
        case .unsupported:
            print("Bluetooth status is UNSUPPORTED")
        case .unauthorized:
            print("Bluetooth status is UNAUTHORIZED")
        case .poweredOff:
            print("Bluetooth status is POWERED OFF")
        case .poweredOn:
            print("Bluetooth status is POWERED ON")
        @unknown default:
            print("Bluetooth status is Unknown")
        }
        
        if central.state == .poweredOn {
            DispatchQueue.main.async { () -> Void in
                self.setState(bleState.On)
            }
        }
        else {
            DispatchQueue.main.async { () -> Void in
                self.setState(bleState.Off)
            }
        }
    }
    
    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String : Any], rssi RSSI: NSNumber) {
        
        let pername = peripheral.name ?? "<No Device Name>"
        
        if !devices.contains(peripheral) {
            print("Found \(pername)")
        }
        
        // add peripheral to array
        //
        if !devices.contains(peripheral) {
            print("Added \(pername)")
            devices += [peripheral]
            rssiTab += [0]
            let serviceInfo = advertisementData[CBAdvertisementDataServiceDataKey] as? [CBUUID: Data]
            if serviceInfo != nil && serviceInfo![CBUUID(string: "F00D")] != nil{
                infoTab += [serviceInfo![CBUUID(string: "F00D")]!]
            } else {
                infoTab += [Data()];
            }
            DispatchQueue.main.async {
                self.deviceTable.reloadData()
            }
        }
        
        // set rssi in rssi tab
        for index in 0..<devices.count {
            if devices[index] == peripheral {
                let rssi = Int(RSSI.intValue)
                if rssi != rssiTab[index] {
                    rssiTab[index] = rssi
                    DispatchQueue.main.async {
                        self.deviceTable.reloadData()
                    }
                }
            }
        }
    }
    
    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        let pername = peripheral.name ?? "<No Device Name>"
        print("Connected to \(pername)")
        DispatchQueue.main.async { () -> Void in
            self.setState(bleState.Connected)
            self.accessoryConnected(name: pername)
            peripheral.discoverServices(nil)
        }
    }
    
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        if let pn = peripheral.name {
            print("Disconnected from \(pn)")
        }
        else {
            print("Disconnected from anonymous periperhal")
        }
        DispatchQueue.main.async { () -> Void in
            // reset state
            self.setState(bleState.Searching)
            self.accessoryDisconnected()
        }
    }
    
    @IBAction func OnConnect(_ sender: Any) {
        if state == .Connected {
            setState(.Disconnecting)
        }
        else if state == .Selected {
            setState(.Connecting)
        }
    }
    
    //MARK: CBPeripheralDelegate interface
    
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?)
    {
        for service in peripheral.services! {
            peripheral.discoverCharacteristics([UWB_Data_RX_CBUUID, UWB_Data_Tx_CBUUID], for: service)
        }
    }
    
    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error = error {
            print("Error disco char \(error.localizedDescription)")
        }
        var gotRx : Bool = false
        var gotTx : Bool = false
        
        for achar in service.characteristics! {
            if achar.uuid == UWB_Data_RX_CBUUID {
                rxChar = achar
                gotRx = true
                if rxChar != nil {
                    peripheral.setNotifyValue(true, for: rxChar!)
                }
            }
            else if achar.uuid == UWB_Data_Tx_CBUUID {
                txChar = achar
                gotTx = true
            }
        }
        
        if gotRx && gotTx {
            DispatchQueue.main.async { () -> Void in
                self.accessoryConnected(name: "crap")
            }
        }
    }
    
    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor: CBCharacteristic, error: Error?) {
        DispatchQueue.main.async { () -> Void in
            if let ecode = error {
                let ch = didWriteValueFor
                print(ch)
                print(ecode)
            }
        }
    }
    
    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if characteristic == rxChar {
            // Check if the peripheral reported an error.
            if let error = error {
                print("Error discovering characteristics:\(error.localizedDescription)")
                return
            }
            guard let characteristicData = characteristic.value else { return }
        
            let str = characteristicData.map { String(format: "0x%02x, ", $0) }.joined()
            print("Received \(characteristicData.count) bytes: \(str)")
            accessorySharedData(data: characteristicData)
        }
    }
    
    // MARK: NearbyInteractionDelegate interface
    
    func session(_ session: NISession, didGenerateShareableConfigurationData shareableConfigurationData: Data, for object: NINearbyObject) {

        guard object.discoveryToken == configuration?.accessoryDiscoveryToken else { return }
        
        // Prepare to send a message to the accessory.
        var msg = Data([MessageId.configureAndStart.rawValue])
        msg.append(shareableConfigurationData)
        
        let str = msg.map { String(format: "0x%02x, ", $0) }.joined()
        print("Sending shareable configuration bytes: \(str)")
        
        sendDataToAccessory(msg)
    }
    
    func session(_ session: NISession, didUpdate nearbyObjects: [NINearbyObject]) {
        guard let accessory = nearbyObjects.first else { return }
        guard let distance = accessory.distance else { return }
        
        //print("distance \(distance)")
        DispatchQueue.main.async { () -> Void in
            self.distanceDisplay.text = String(format: "%0.2fm", distance)
            
            if let hangle = accessory.horizontalAngle {
                var azimuth = hangle
                if azimuth < -60.0 {
                    azimuth = -60.0
                }
                else  if azimuth > 60.0 {
                    azimuth = 60.0
                }
                self.azimSlider.value = azimuth
            }
        }
    }
    
    func session(_ session: NISession, didRemove nearbyObjects: [NINearbyObject], reason: NINearbyObject.RemovalReason) {
        // Retry the session only if the peer timed out.
        guard reason == .timeout else { return }

        DispatchQueue.main.async { () -> Void in
            self.setState(.Disconnecting)
        }
    }
    
    func sessionWasSuspended(_ session: NISession) {
        //updateInfoLabel(with: "Session was suspended.")
        let msg = Data([MessageId.stop.rawValue])
        sendDataToAccessory(msg)
        DispatchQueue.main.async { () -> Void in
            self.setState(.Disconnecting)
        }
   }
    
    func sessionSuspensionEnded(_ session: NISession) {
        //updateInfoLabel(with: "Session suspension ended.")
        // When suspension ends, restart the configuration procedure with the accessory.
        let msg = Data([MessageId.initialize.rawValue])
        sendDataToAccessory(msg)
    }
    
    func session(_ session: NISession, didInvalidateWith error: Error) {
        switch error {
        case NIError.invalidConfiguration:
            // Debug the accessory data to ensure an expected format.
            print("The accessory configuration data is invalid. Please debug it and try again.")
        case NIError.userDidNotAllow:
            handleUserDidNotAllow()
        default:
            handleSessionInvalidation()
        }
    }

    // MARK: Helpers
    
    func sendDataToAccessory(_ data: Data) {
        guard let thePeripheral = foundPeripheral,
              let transferCharacteristic = txChar
        else { return }

        let mtu = thePeripheral.maximumWriteValueLength(for: .withResponse)

        let bytesToCopy: size_t = min(mtu, data.count)

        var rawPacket = [UInt8](repeating: 0, count: bytesToCopy)
        data.copyBytes(to: &rawPacket, count: bytesToCopy)
        let packetData = Data(bytes: &rawPacket, count: bytesToCopy)

        let stringFromData = packetData.map { String(format: "0x%02x, ", $0) }.joined()
        print("Writing \(bytesToCopy) bytes: \(String(describing: stringFromData))")

        thePeripheral.writeValue(packetData, for: transferCharacteristic, type: .withResponse)
    }
    
    func handleSessionInvalidation() {
        print("Session invalidated. Restarting.")
        // Ask the accessory to stop.
        sendDataToAccessory(Data([MessageId.stop.rawValue]))

        // Replace the invalidated session with a new one.
        self.niSession = NISession()
        self.niSession.delegate = self

        // Ask the accessory to stop.
        sendDataToAccessory(Data([MessageId.initialize.rawValue]))
    }
      
    func handleUserDidNotAllow() {
        // Beginning in iOS 15, persistent access state in Settings.
        print("Nearby Interactions access required. You can change access for NIAccessory in Settings.")
        
        // Create an alert to request the user go to Settings.
        let accessAlert = UIAlertController(title: "Access Required",
                                            message: """
                                            NIAccessory requires access to Nearby Interactions for this sample app.
                                            Use this string to explain to users which functionality will be enabled if they change
                                            Nearby Interactions access in Settings.
                                            """,
                                            preferredStyle: .alert)
        accessAlert.addAction(UIAlertAction(title: "Cancel", style: .cancel, handler: nil))
        accessAlert.addAction(UIAlertAction(title: "Go to Settings", style: .default, handler: {_ in
            // Navigate the user to the app's settings.
            if let settingsURL = URL(string: UIApplication.openSettingsURLString) {
                UIApplication.shared.open(settingsURL, options: [:], completionHandler: nil)
            }
        }))

        // Preset the access alert.
        present(accessAlert, animated: true, completion: nil)
    }
}
