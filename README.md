# ECGSOLAX-ECG-HVM3.6K-24V +++ NEED to SOLVE HW or SW USB EMI DISCONNECT +++

<img width="1589" height="941" alt="ecgsolax" src="https://github.com/user-attachments/assets/5c0890ee-728f-4337-af91-479dcab7361b" />  

A complete monitoring solution for ECGSOLAX inverters using Modbus RS232 communication, converting metrics to MQTT, and visualizing data through a Grafana dashboard via the TIG Stack (Telegraf, InfluxDB, Grafana).

## Hardware Setup

The inverter communicates via a 'undercover USB' type A socket that is in fact a RS232 +- 12V level serial interface (COM 8).  
To connect to a Raspberry Pi:

1. **Components Needed:**
   - USB to RS232-DB9-male converter
   - Spare USB A cable (wired to connect the 'undercover USB' (COM 8) to the DB9 of our USB to RS232 converter)  

2. **Wiring COM8 to Serial converter DB9 via USB type A cable:**
   - Red (5V?) — Not used
   - Green — Pin 2 DB9 (RX)
   - White — Pin 3 DB9 (TX)
   - Black — Pin 5 DB9 (GND)

## Software Stack

- **OS**: DietPI (Raspberry Pi 5, ARMv8)
- **Core Application**: Python 3 (Modbus RTU via minimalmodbus)
- **Messaging**: MQTT (Mosquitto broker)
- **Time-Series Database**: InfluxDB
- **Data Collection**: Telegraf
- **Visualization**: Grafana

## Installation

### 1. Prepare the SD Card

Download the DietPI image:
```bash
wget https://dietpi.com/downloads/images/DietPi_RPi5-ARMv8-Trixie.img.xz
```

Decompress:
```bash
unxz DietPi_RPi5-ARMv8-Trixie.img.xz
```

Find mount points:
```bash
sudo fdisk -l DietPi_RPi5-ARMv8-Trixie.img
```

Mount the filesystem (adjust offset as needed):
```bash
mkdir /media/sdcard
sudo mount -o loop,rw,sync,offset=135266304 DietPi_RPi5-ARMv8-Trixie.img /media/sdcard
```

### 2. Configure DietPI

Copy provided configuration files to `/media/sdcard/boot/`:
- `dietpi.txt` — DietPI configuration
- `Automation_Custom_Script.sh` — Initial setup script

Set permissions:
```bash
sudo chmod 777 ./dietpi.txt ./Automation_Custom_Script.sh
sudo umount /media/sdcard
```

### 3. Deploy to Raspberry Pi

1. Burn the `.img` file to SD card using a tool like Balena Etcher or `dd`
2. Insert SD card into Raspberry Pi 5
3. Power on and wait for Grafana to become accessible at **http://192.168.1.11:3000** !!this could last few good minutes depending on the internet connection!!

### 4. Configure Grafana

1. **Initial Access**: Log in with default Grafana credentials admin/admin and change the username and password as you wish
2. **Add InfluxDB Data Source**:
   - URL: `http://localhost:8086`
   - Database: `solar`
   - User: `apollo`
   - Password: `apollo`
   - Click "Save & test" button to verify database connectivity
3. **Import Dashboard**: Import the provided Grafana dashboard JSON file or create your own

## Application Architecture

### Python Core (`ecgsolax.py`)

The Python application handles:

- **Modbus Communication**: Reads registers from the ECGSOLAX inverter via RS232/RTU
- **Metric Collection**: 
  - Inverter state & faults
  - Battery metrics (voltage, current, SOC, SOH)
  - PV array metrics (voltage, current, power, energy)
  - Mains metrics (voltage, power, consumption)
  - Load metrics (power, energy, load percentage)
  - Thermal metrics (heatsink & ambient temperature)
  - Fan metrics (speed, status)
  - Charging parameters & settings
- **MQTT Publishing**: Sends metrics in InfluxDB Line Protocol format for automatic ingestion by Telegraf
- **Error Handling**: Automatic retries with comprehensive logging

### Shell Automation (`Automation_Custom_Script.sh`)

The shell script automates:
- Installation of TIG Stack components
- MQTT broker configuration
- Python environment setup
- Systemd service enablement
- Cron-based daemon startup

## Metrics Published

Metrics are published to MQTT topic `mydata` with device tags (inverter name, port, serial number):

- `inverter_metrics` — Real-time inverter output and battery status
- `inverter_bms_metrics` — Battery management system data
- `inverter_mains_metrics` — Grid voltage and consumption
- `inverter_load_metrics` — AC output load and energy
- `inverter_pv_metrics` — Solar array performance
- `inverter_fan_metrics` — Cooling system status
- `inverter_temp_metrics` — Device temperatures
- `inverter_program_metrics` — Configuration parameters

## Dashboard Preview

<img width="1920" height="1080" alt="Grafana Dashboard" src="https://github.com/user-attachments/assets/2d34a69a-8b78-4645-87f0-67b2661922a2" />

## Topics

- Modbus RTU communication
- MQTT pub/sub messaging
- InfluxDB time-series database
- Grafana visualization
- Python3 scripting
- Telegraf metrics aggregation

## License

MIT License - See LICENSE file for details

---

**Enjoy monitoring your ECGSOLAX inverter!** ☀️
