#!/bin/bash

echo "Starting installation of TIG Stack + MQTT..."
wget https://repos.influxdata.com/debian/packages/influxdb_1.12.2-4_arm64.deb
sudo dpkg -i ./influxdb_1.12.2-4_arm64.deb
rm ./influxdb_1.12.2-4_arm64.deb
sudo sed -i 's/# flux-enabled = false/flux-enabled = true/g' /etc/influxdb/influxdb.conf
sudo systemctl unmask influxdb.service
sudo systemctl enable --now influxdb
sleep 1

curl -s "http://localhost:8086/query" --data-urlencode "q=CREATE DATABASE solar"
curl -s "http://localhost:8086/query" --data-urlencode "q=CREATE USER apollo WITH PASSWORD 'apollo' WITH ALL PRIVILEGES"
curl -s "http://localhost:8086/query" --data-urlencode "q=GRANT ALL PRIVILEGES ON solar TO apollo"

sudo mkdir -p /etc/apt/keyrings/
wget -q -O - https://apt.grafana.com/gpg.key | gpg --dearmor | sudo tee /etc/apt/keyrings/grafana.gpg > /dev/null
echo "deb [signed-by=/etc/apt/keyrings/grafana.gpg] https://apt.grafana.com stable main" | sudo tee /etc/apt/sources.list.d/grafana.list
sudo apt update
sudo apt install -y grafana mosquitto mosquitto-clients python3-pip mc
sleep 1
sudo systemctl unmask grafana-server.service
sudo systemctl enable --now grafana-server

printf "allow_anonymous true\nlistener 1883 0.0.0.0\n" | sudo tee /etc/mosquitto/conf.d/mosquitto.conf
sudo systemctl enable --now mosquitto

sudo mkdir -p /etc/
printf "[global]\nbreak-system-packages = true\n" | sudo tee /etc/pip.conf
sudo pip3 install influxdb-client "paho-mqtt<2.0.0" pyserial crcmod minimalmodbus

wget -q https://repos.influxdata.com/debian/packages/telegraf_1.37.0-1_arm64.deb
sudo dpkg -i ./telegraf_1.37.0-1_arm64.deb
rm ./telegraf_1.37.0-1_arm64.deb

cat <<EOF | sudo tee /etc/telegraf/telegraf.d/mqtt-input.conf
[[inputs.mqtt_consumer]]
  servers = ["tcp://127.0.0.1:1883"]
  topics = [
    "#",
  ]
  data_format = "influx"
EOF

cat <<EOF | sudo tee /etc/telegraf/telegraf.d/influx-output.conf
[[outputs.influxdb]]
  urls = ["http://127.0.0.1:8086"]
  database = "solar"
  skip_database_creation = true
  username = "apollo"
  password = "apollo"
EOF
sudo systemctl unmask telegraf.service
sudo systemctl enable --now telegraf

sudo mkdir /usr/share/solar

cat <<EOF | sudo tee /usr/share/solar/ecgsolax.py
#!/usr/bin/python3

import sys                                                              # Import sys for logging to stdout                        
import time                                                             # Import time for sleep and timing operations
import logging                                                          # Import logging for logging operations
import minimalmodbus                                                    # Import minimalmodbus for Modbus communication
import paho.mqtt.client as mqtt                                         # Import paho.mqtt.client for MQTT communication

# Config
MQTT_BROKER = "192.168.1.11"                                            # MQTT broker address
MQTT_PORT = 1883                                                        # MQTT broker port
MQTT_TOPIC = "mydata"                                                   # MQTT topic for publishing telemetry data
PORT_PREFIX = '/dev/ttyUSB'                                             # Serial port prefix for Modbus communication
INVERTER_COUNT = 1                                                      # Number of inverters connected on consecutive serial ports
SLAVE_ADDRESS = 1                                                       # Physical Modbus address of the inverter
INVERTER_NAMES = [f"inverter{i+1}" for i in range(INVERTER_COUNT)]      # Human-friendly inverter names

# Modbus device state
devices = []                                                            # List to hold the initialized inverter devices
current_device = None                                                   # Current device None

# Logging Setup
logging.basicConfig(                                                    # Configure logging
    level=logging.ERROR,                                                # Set log level to ERROR
    format="%(asctime)s - %(levelname)s - %(message)s",                 # Set log format
    datefmt="%Y-%m-%d %H:%M:%S",                                        # Set date format
    handlers=[                                                          # Set log handlers
        logging.FileHandler("ECGSOLAX_modbus_to_mqtt.log"),             # Log to file
        logging.StreamHandler(sys.stdout),                              # Log to console
    ],
)
logger = logging.getLogger(__name__)                                    # Create a logger instance

try:                                                                    # Helper: MQTT Setup (Compatible with Paho v1 and v2)
    mqtt_client = mqtt.Client(mqtt.CallbackAPIVersion.VERSION2)         # MQTT client instance with callback API version 2
except AttributeError:                                                  # Exception handling for older versions of Paho MQTT
    mqtt_client = mqtt.Client()                                         # MQTT client instance for older versions of Paho MQTT


def create_inverter_device(port, slave_address, name):                  # Helper: Create a configured minimalmodbus inverter device
    inverter = minimalmodbus.Instrument(port, slave_address)            # suggested by minimalmodbus documentation
    inverter.mode = minimalmodbus.MODE_RTU                              # use RTU mode for Modbus communication
    inverter.serial.baudrate = 9600                                     # Set baud rate for serial communication
    inverter.serial.bytesize = 8                                        # Set byte size for serial communication
    inverter.serial.parity = minimalmodbus.serial.PARITY_NONE           # Set parity for serial communication
    inverter.serial.stopbits = 1                                        # Set stop bits for serial communication
    inverter.serial.timeout = 1.0                                       # Set timeout for serial communication
    inverter.serial.write_timeout = 1.0                                 # Set write timeout for serial communication
    inverter.serial.xonxoff = False                                     # Set XON/XOFF for serial communication
    inverter.serial.rtscts = False                                      # Set RTS/CTS for serial communication
    inverter.serial.dsrdtr = False                                      # Set DSR/DTR for serial communication
    inverter.clear_buffers_before_each_transaction = True               # Clear buffers before each transaction
    inverter.close_port_after_each_call = True                          # Close port after each call
    return {                                                            # Return a dictionary representing the inverter device with its configuration
        "name": name,                                                   # Human-friendly name of the inverter
        "port": port,                                                   # Serial port for Modbus communication
        "slave_address": slave_address,                                 # Physical Modbus address of the inverter
        "instrument": inverter,                                         # Configured minimalmodbus.Instrument instance for Modbus communication
        "serial_number": None,                                          # Placeholder for the inverter serial number (to be read later)  
        "tags": {"inverter": name, "port": port},                       # Tags for MQTT publishing, including inverter name and port
    }


def set_device(device):                                                     # Helper: Set the current active inverter device
    global current_device                                                   # Declare current_device as global to modify it 
    current_device = device                                                 # Set the current active inverter device to the provided device


def read_serial_number(device):                                                                             # Helper: Read the inverter serial number from register 0
    try:                                                                                                    # Read the serial number from the inverter using Modbus function code 3 (Read Holding Registers)
        serial_number = device["instrument"].read_register(0, functioncode=3)                               # Read the serial number from register 0 using Modbus function code 3 (Read Holding Registers)
        device["serial_number"] = serial_number                                                             # Store the read serial number in the device dictionary
        device["tags"]["serial"] = str(serial_number)                                                       # Store the read serial number as a string in the device tags dictionary
        return serial_number                                                                                # Return the read serial number
    except Exception as e:                                                                                  # Log a warning if reading the serial number fails and set the serial number to 0 and the tag to "unknown"
        logger.warning(f"Failed to read serial number from {device['name']} at {device['port']}: {e}")      # Log warning message with device name, port, and exception details
        device["serial_number"] = 0                                                                         # Set the serial number to 0 in the device dictionary
        device["tags"]["serial"] = "unknown"                                                                # Set the serial number tag to "unknown" in the device tags dictionary
        return 0                                                                                            # Return 0 if reading the serial number fails


def init_inverters():                                                                                                       # Helper: Initialize all inverter devices
    result = []                                                                                                             # Create an empty list to hold the initialized inverter devices
    for index in range(INVERTER_COUNT):                                                                                     # Create consecutive serial port names
        port = f"{PORT_PREFIX}{index}"                                                                                      # Construct the serial port name for the current inverter
        device = create_inverter_device(port, SLAVE_ADDRESS, INVERTER_NAMES[index])                                         # Create a configured minimalmodbus inverter device for the current serial port
        read_serial_number(device)                                                                                          # Read the serial number from the inverter and store it in the device dictionary
        result.append(device)                                                                                               # Add the initialized device to the result list 
        logger.info(f"Initialized {device['name']} on {device['port']} with serial={device['serial_number']}")              # Log the successful initialization of the inverter device with its name, port, and serial number
    return result                                                                                                           # Return the list of initialized inverter devices              


def init_mqtt():                                                        # Helper: Initialize MQTT connection
    try:                                                                # Try to connect to the MQTT broker
        mqtt_client.connect(MQTT_BROKER, MQTT_PORT, keepalive=60)       # Connect to the MQTT broker with a keepalive of 60 seconds
        mqtt_client.loop_start()                                        # Start the MQTT background loop
        logger.info("MQTT Background Loop successfully initialized.")   # Log successful initialization of MQTT background loop
    except Exception as e:                                              # Log error if MQTT connection fails
        logger.error(f"MQTT connection failed: {e}")                    # Log error message with exception details

def read_block(start_addr, count):                                                                                                   # Helper: Read a contiguous block of registers with retries
    if current_device is None:                                                                                                       # Check if a current device is selected for Modbus read
        logger.error("No current device selected for Modbus read")                                                                   # Log error message if no current device is selected
        return None                                                                                                                  # Return None if no current device is selected
    for attempt in range(1, 4):                                                                                                      # Try up to 3 times to read the block of registers
        try:                                                                                                                         # Try to read the block registers  
            return current_device["instrument"].read_registers(start_addr, count, functioncode=3)                                    # Read the block of registers using function code 3 (Read Holding Registers)
        except Exception as e:                                                                                                       # Log a warning if reading the block of registers fails and retry after a short sleep
            logger.warning(f"{current_device['name']} attempt {attempt} failed reading {start_addr}+{count-1}: {e}")                 # Log warning message with attempt number, start address, count, and exception details
            time.sleep(0.2)                                                                                                          # Sleep for 0.2 seconds before retrying
    logger.error(f"{current_device['name']} failed to read Modbus block [{start_addr}..{start_addr + count - 1}] after retries")     # Log error message if all attempts to read the block of registers fail
    return None                                                                                                                      # Return None if reading the block of registers fails after all retries


def to_signed16(val):                                                       # Helper: Convert a uint16 value to a signed int16 value
    return val - 65536 if val > 32767 else val                              # Return the signed int16 value if the uint16 value is greater than 32767, otherwise return the original value

def get_32bit(regs, high_idx, low_idx):                                     # Helper: Read and Combines two uint16 registers into a uint32 value
    if not regs or high_idx >= len(regs) or low_idx >= len(regs):           # Check if the register list is valid and the indices are within bounds
        return 0                                                            # Return 0 if the register list is invalid or the indices are out of bounds
    return (regs[high_idx] << 16) | regs[low_idx]                           # Return the combined uint32 value by shifting the high register left by 16 bits and OR'ing it with the low register

                                                                            
def publish_metrics(measurement_name, metrics_dict):                                                                            # Helper: Publish metrics to MQTT in InfluxDB Line Protocol format
    if not metrics_dict:                                                                                                        # Check if the metrics dictionary is empty
        logger.warning(f"No metrics to publish for {measurement_name}.")                                                        # Log a warning if there are no metrics to publish for the given measurement name
        return                                                                                                                  # Return early if there are no metrics to publish
    fields = [f"{key}={val}" for key, val in metrics_dict.items()]                                                              # Create a list of field strings in the format "key=value" for each metric in the metrics dictionary
    tags = current_device["tags"] if current_device else {}                                                                     # Create a dictionary of tags for the current device, or an empty dictionary if there is no current device
    tag_string = ",".join(f"{key}={str(value).replace(' ', '\\ ')}" for key, value in tags.items())                             # Create a string of tags in the format "key=value" for each tag in the tags dictionary, replacing spaces with escaped spaces
    payload = f"{measurement_name},{tag_string} {','.join(fields)}" if tag_string else f"{measurement_name} {','.join(fields)}" # Create the payload string in InfluxDB Line Protocol format, including the measurement name, tags, and fields
    mqtt_client.publish(MQTT_TOPIC, payload, qos=0, retain=False)                                                               # Publish the payload to the MQTT topic with QoS 0 and no retain flag
    logger.info(f"📡 Published {measurement_name} to {MQTT_TOPIC} with tags {tags}")                                            # Log successful publishing of metrics

# -------------------------------------------------------------
# Telemetry Collectors (Using Fast Block Reads)
# -------------------------------------------------------------

def collect_program_metrics():                                              # Collects program metrics from the inverter and publishes them to MQTT
    regs = read_block(16640, 68)                                            # Read 68 registers from 16640 to 16684 in 1 single Modbus command!
    if not regs:                                                            # Check if the register read was successful
        return 0                                                            # Return early if the register read failed
    metrics = {                                                             # Create a dictionary of program metrics with register values
        "programed_output_voltage": regs[0],                                # register 16640
        "programed_output_frequency": regs[1],                              # register 16641
        "programed_output_priority": regs[2],                               # register 16642
        "programed_operating_mode": regs[3],                                # register 16643
        "programed_charging_priority": regs[4],                             # register 16644
        "programed_charging_current": regs[5],                              # register 16645
        "programed_max_charging_current": regs[6],                          # register 16646
        "programed_battery_type": regs[7],                                  # register 16647
        "programed_battery_low_voltage": regs[8],                           # register 16648
        "programed_battery_shutdown": regs[9],                              # register 16649
        "programed_bulk_charge_voltage": regs[10],                          # register 16650
        "programed_float_charge_voltage": regs[11],                         # register 16651
        "programed_battery_depleted_voltage": regs[12],                     # register 16652
        "programed_return_to_battery_voltage": regs[13],                    # register 16653
        "programed_low_mains_voltage": regs[14],                            # register 16654
        "programed_high_mains_voltage": regs[15],                           # register 16655
        "programed_parallel_mode": regs[16],                                # register 16656
        "programed_number_of_parallel_units": regs[17],                     # register 16657
        "programed_equalization_enable": regs[18],                          # register 16658
        "programed_equalization_voltage": regs[19],                         # register 16659
        "programed_equalization_time": regs[20],                            # register 16660
        "programed_equalization_delay_time": regs[21],                      # register 16661
        "programed_equalization_interval": regs[22],                        # register 16662
        "programed_equalization_now": regs[23],                             # register 16663
        "programed_cutoff_voltage": regs[24],                               # register 16664
        "programed_generator_enable": regs[26],                             # register 16666
        "programed_generator_rated_power": regs[27],                        # register 16667
        "programed_generator_max_power": regs[28],                          # register 16668
        "programed_bms_protocol": regs[30],                                 # register 16670
        "programed_bms_id_selection": regs[31],                             # register 16671
        "programed_low_soc_shutdown": regs[32],                             # register 16672
        "programed_battery_soc_set": regs[33],                              # register 16673
        "programed_battery_soc_switch_ac": regs[34],                        # register 16674
        "programed_on_off_enable": regs[35],                                # register 16675
        "programed_turn_off_charging": regs[36],                            # register 16676
        "programed_auto_off_backlight": regs[37],                           # register 16677
        "programed_overheating_restart": regs[39],                          # register 16679
        "programed_overload_restart": regs[40],                             # register 16680
        "programed_overload_bypass": regs[41],                              # register 16681
        "programed_eco_mode": regs[42],                                     # register 16682
        "programed_frequency_mains_autodetect": regs[43],                   # register 16683
        "programed_softstart": regs[44],                                    # register 16684
        "programed_battery_open_circuit": regs[45],                         # register 16685
        "programed_buzer_mute": regs[48],                                   # register 16688
        "programed_return_to_main_display": regs[49],                       # register 16689
        "programed_mains_change_warning": regs[50],                         # register 16690
        "programed_restore_default_settings": regs[51],                     # register 16691
        "programed_seconds": regs[52],                                      # register 16692
        "programed_minute": regs[53],                                       # register 16693
        "programed_hour": regs[54],                                         # register 16694
        "programed_day": regs[55],                                          # register 16695
        "programed_month": regs[56],                                        # register 16696
        "programed_year": regs[57],                                         # register 16697
        "programed_power_on": regs[62],                                     # register 16702
        "programed_power_off": regs[63],                                    # register 16703
        "programed_max_inverter_current": regs[66]                          # register 16706
    }
    publish_metrics("inverter_program_metrics", metrics)                    # Publish the collected program metrics to MQTT

def collect_inverter_metrics():                                               # Collects inverter metrics from the inverter and publishes them to MQTT
    blk1 = read_block(66, 7)                                                  # Read 66 to 72
    blk2 = read_block(88, 3)                                                  # Read 88 to 90
    blk3 = read_block(128, 12)                                                # Read 128 to 139
    blk4 = read_block(158, 1)                                                 # Read 158
    blk5 = read_block(374, 12)                                                # Read 374 to 385
    if any(not block for block in [blk1, blk2, blk3, blk4, blk5]):            # Check if any of the blocks are None (indicating a read failure)
        return 0                                                              # Return early if any of the blocks failed to read
    metrics = {                                                               # Create a dictionary of inverter metrics with register values
        "machine_state": blk1[0],                                             # register 66  
        "fault_code": blk1[4],                                                # register 70
        "alarm_code": blk1[6],                                                # register 72
        "inverter_output_voltage": blk2[0] /10,                               # register 88
        "inverter_output_current": blk2[1] /100,                              # register 89
        "inverter_output_frequency": blk2[2] /100,                            # register 90
        "inverter_battery_voltage": blk3[0] /10,                              # register 128
        "inverter_current_from_to_battery": (to_signed16(blk3[1]) /10) * -1,  # register 129
        "inverter_calculated_soc": blk3[4],                                   # register 132
        "inverter_power_from_to_battery": to_signed16(blk3[5]) * -1,          # register 133
        "inverter_bms_battery_voltage": blk3[8] /10,                          # register 136
        "inverter_bms_charge_discharge_current": blk3[9] /100,                # register 137
        "inverter_bms_battery_soc": blk3[10],                                 # register 138
        "inverter_charging_current": (blk4[0] /100) if blk4 else 0,           # register 158
        "inverter_charging_mode": blk5[0],                                    # register 374
        "inverter_cccv_voltage": blk5[1] /10,                                 # register 375
        "inverter_float_voltage": blk5[2] /10,                                # register 376
        "inverter_cvcc_max_current": blk5[3] /100,                            # register 377
        "inverter_switch_to_float_current": blk5[4] /100,                     # register 378
        "inverter_cc_charging_time": blk5[5],                                 # register 379
        "inverter_cv_charging_time": blk5[6],                                 # register 380
        "inverter_equalization_voltage": blk5[8]/10,                          # register 382
        "inverter_equalization_time": blk5[9],                                # register 383
        "inverter_equalization_delay": blk5[10],                              # register 384
        "inverter_equalization_interval": blk5[11]                            # register 385
    }
    publish_metrics("inverter_metrics", metrics)                              # Publish the collected inverter metrics to MQTT

def collect_mains_metrics():                                                # Collects mains metrics from the inverter and publishes them to MQTT
    regs = read_block(432, 23)                                              # Read registers 432 to 454
    if not regs:                                                            # Check if the register read was successful
        return 0                                                            # Return early if the register read failed
    metrics = {                                                             # Create a dictionary of mains metrics with register values
        "mains_voltage": regs[0] / 10.0,                                    # register 432
        "mains_power": regs[3],                                             # register 435
        "mains_daily_consumption": get_32bit(regs, 15, 16) /100,            # register 447, 448
        "mains_monthly_consumption": get_32bit(regs, 17, 18) /100,          # register 449, 450
        "mains_anual_consumption": get_32bit(regs, 19, 20) /100,            # register 451, 452
        "mains_total_consumption": get_32bit(regs, 21, 22) /100             # register 453, 454
    }
    publish_metrics("inverter_mains_metrics", metrics)                      # Publish the collected mains metrics to MQTT

def collect_load_metrics():                                                 # Collects load metrics from the inverter and publishes them to MQTT    
    regs = read_block(540, 13)                                              # Read registers 540 to 552
    if not regs:                                                            # Check if the register read was successful
        return 0                                                            # Return early if the register read failed
    metrics = {                                                             # Create a dictionary of load metrics with register values
        "inverter_active_power": regs[0],                                   # register 540
        "inverter_apparent_power": regs[1],                                 # register 541
        "inverter_load_percent": regs[4],                                   # register 544
        "inverter_daily_energy": get_32bit(regs, 5, 6) /100,                # register 545, 546
        "inverter_monthly_energy": get_32bit(regs, 7, 8) /100,              # register 547, 548
        "inverter_year_energy": get_32bit(regs, 9, 10) /100,                # register 549, 550
        "inverter_total_energy": get_32bit(regs, 11, 12) /100               # register 551, 552
    }
    publish_metrics("inverter_load_metrics", metrics)                       # Publish the collected load metrics to MQTT

def collect_bms_metrics():                                                  # Collects BMS metrics from the inverter and publishes them to MQTT
    regs = read_block(402, 10)                                              # Read registers 402 to 411
    if not regs:                                                            # Check if the register read was successful
        return 0                                                            # Return early if the register read failed
    metrics={                                                               # Create a dictionary of BMS metrics with register values
        "bms_communication_status": regs[0],                                # register 402
        "bms_battery_voltage": regs[1] /10,                                 # register 403
        "bms_battery_current": regs[2] /100,                                # register 404
        "bms_battery_temperature": regs[3] /10,                             # register 405
        "bms_battery_soc": regs[4] /1,                                      # register 406
        "bms_battery_soh": regs[5],                                         # register 407
        "bms_remaining_ah": regs[6] /10,                                    # register 408
        "bms_full_ah": regs[7] /10,                                         # register 409
        "bms_requested_voltage": regs[8] /10,                               # register 410
        "bms_max_current_limited": regs[9] /10                              # register 411
    }
    publish_metrics("inverter_bms_metrics", metrics)                        # Publish the collected BMS metrics to MQTT

def collect_pv_metrics():                                                   # Collects PV metrics from the inverter and publishes them to MQTT
    regs = read_block(624, 14)                                              # Read registers 624 to 636
    if not regs:                                                            # Check if the register read was successful
        return 0                                                            # Return early if the register read failed  
    metrics = {                                                             # Create a dictionary of PV metrics with register values
        "inverter_pv_voltage": regs[0] /10,                                 # register 624
        "inverter_pv_current": regs[1] /100,                                # register 625
        "inverter_pv_power": regs[2],                                       # register 626
        "inverter_pv_track": regs[3],                                       # register 627
        "inverter_pv_daily_energy": get_32bit(regs, 5, 6) /100,             # register 628, 629
        "inverter_pv_monthly_energy": get_32bit(regs, 7, 8) /100,           # register 630, 631
        "inverter_pv_year_energy": get_32bit(regs, 9, 10) /100,             # register 632, 633
        "inverter_pv_total_energy": get_32bit(regs, 11, 12) /100            # register 634, 635
    }
    publish_metrics("inverter_pv_metrics", metrics)                         # Publish the collected PV metrics to MQTT

def collect_fan_metrics():                                                  # Collects fan metrics from the inverter and publishes them to MQTT
    regs = read_block(800, 2)                                               # Read registers 800 to 801
    if not regs:                                                            # Check if the register read was successful
        return 0                                                            # Return early if the register read failed
    metrics={                                                               # Create a dictionary of fan metrics with register values
        "Inverter_fan_speed": regs[0],                                      # register 800
        "inverter_fan_status": regs[1],                                     # register 801
    }   
    publish_metrics("inverter_fan_metrics", metrics)                        # Publish the collected fan metrics to MQTT

def collect_temp_metrics():                                                 # Collects temperature metrics from the inverter and publishes them to MQTT                 
    regs = read_block(816, 5)                                               # Read registers 816 to 820        Sumary verifyed
    if not regs:                                                            # Check if the register read was successful
        return 0                                                            # Return early if the register read failed
    metrics={                                                               # Create a dictionary of temperature metrics with register values
        "inverter_heatsink_temperature": regs[0],                           # register 816
        "inverter_ambient_temperature": regs[4]                             # register 820
    }   
    publish_metrics("inverter_temp_metrics", metrics)                       # Publish the collected temperature metrics to MQTT

# -------------------------------------------------------------
# Main Daemon Loop
# -------------------------------------------------------------

if __name__ == "__main__":                                                  # Main entry point of the script
    logger.info("Starting ECGSOLAX Modbus MQTT Daemon Process")             # Log the start of the daemon process
    init_mqtt()                                                             # Initialize the MQTT connection
    devices = init_inverters()                                              # Initialize all inverter devices
    POLL_INTERVAL = 5.0                                                     # Set the polling interval in seconds     
    try:                                                                    # Start the main loop to collect and publish metrics
        while True:                                                         # Loop indefinitely to collect and publish metrics
            start_time = time.time()                                        # Record the start of the loop iteration
            for device in devices:
                set_device(device)
                collect_inverter_metrics()                                  # Collect and publish inverter metrics to MQTT
                collect_bms_metrics()                                       # Collect and publish BMS metrics to MQTT
                collect_mains_metrics()                                     # Collect and publish mains metrics to MQTT
                collect_load_metrics()                                      # Collect and publish load metrics to MQTT
                collect_pv_metrics()                                        # Collect and publish PV metrics to MQTT
                collect_fan_metrics()                                       # Collect and publish fan metrics to MQTT
                collect_temp_metrics()                                      # Collect and publish temperature metrics to MQTT
                collect_program_metrics()                                   # Collect and publish program metrics to MQTT

            elapsed = time.time() - start_time                              # Calculate the elapsed time for the loop iteration
            sleep_time = max(0.1, POLL_INTERVAL - elapsed)                  # Calculate the sleep time to maintain the polling interval, ensuring a minimum sleep time of 0.1 seconds
            time.sleep(sleep_time)                                          # Sleep for the calculated sleep time before the next loop iteration

    except KeyboardInterrupt:                                               # Handle graceful shutdown on keyboard interrupt (Ctrl+C)       
        logger.info("Stopping background daemons gracefully...")            # Log the graceful shutdown of background daemons
        mqtt_client.loop_stop()                                             # Stop the MQTT background loop
        mqtt_client.disconnect()                                            # Disconnect from the MQTT broker
        logger.info("Script terminated safely.")                            # Log the safe termination of the script    
EOF

cat <<EOF | sudo tee /usr/share/solar/start.sh
#!/bin/bash
nohup /usr/bin/python3 /usr/share/solar/ecgsolax.py &> /dev/null &disown
EOF

crontab -l > mycron
echo "@reboot sleep 10 && /usr/share/solar/start.sh" >> mycron
crontab -u dietpi mycron
sudo rm mycron

sudo usermod -a -G dialout dietpi
sudo chmod +x /usr/share/solar/start.sh
sudo chmod +x /usr/share/solar/ecgsolax.py
sudo chown -R dietpi:dialout /usr/share/solar/

sleep 1
sudo reboot
