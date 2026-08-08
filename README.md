# ECGSOLAX-ECG-HVM3.6K-24V
<img> https://github.com/geobitus/ECGSOLAX-ECG-HVM3.6K-24V/blob/main/ecgsolax.png?raw=true  
The USB socket COM(8) is in fact a communication RS232 serial +-12V level.  

Use an USB/RS232-DB9-male converter connected to the RaspberryPI USB and a spare USB cable wired as described: red = +5V not used, green = pin2 DB9(RX), white = pin3 DB9(TX), black = pin5 DB9(GND) connected to the COM(8) of the inverter.   
That's all the hardware you need.  
As OS I chose the DietPI release for the easiness of deployment and convenience.   
Download the official image from https://dietpi.com/downloads/images/DietPi_RPi5-ARMv8-Trixie.img.xz  
Decompress the ing.xz file:  
-$~ unxz DietPi_RPi5-ARMv8-Trixie.img.xz  
Found the needed info about mount-points:  
-$~ sudo fdisk -l DietPi_RPi5-ARMv8-Trixie.img  

Disk DietPi_RPi5-ARMv8-Trixie.img: 1.07 GiB, 1149407232 bytes, 2244936 sectors  
Units: sectors of 1 * 512 = 512 bytes  
Sector size (logical/physical): 512 bytes / 512 bytes  
I/O size (minimum/optimal): 512 bytes / 512 bytes  
Disklabel type: dos  
Disk identifier: 0xc7ff9455  
Device                        Boot  Start     End Sectors   Size Id Type  
DietPi_RPi5-ARMv8-Trixie.img1 *      2048  264191  262144   128M  c W95 FAT32 (LBA)  
DietPi_RPi5-ARMv8-Trixie.img2      264192 2244935 1980744 967.2M 83 Linux 

-$~ echo $((264192 * 512)) "calculated offset"  
135266304

-$~ mkdir /media/sdcard

-$~ sudo mount -o loop,rw,sync,offset=135266304 DietPi_RPi5-ARMv8-Trixie.img /media/sdcard

-$~ cd /media/sdcard/boot
-Copy/adapt provided or edit your own dietpi.txt & Automation_Custom_Script.sh files into boot directory.

-$~ sudo chmod 777 ./dietpi.txt

-$~ sudo chmod 777 ./Automation_Custom_Script.sh

-$~ sudo umount /media/sdcard

-Burn the .img file to sdcard using a burner at your choice.

-Put the sdcard into the RaspberryPI, power-on and wait until Grafana become accessible @ 192.168.1.11:3000.

-Configure initial Grafana user access and password at your choice.

-In Grafana add data source and select influxdb set http://localhost:8086, Database 'solar', User 'apollo', Password 'apollo' press test button and if you see some measurements you are ready to go.

-Import the provided .json dashboard in Grafana or create your own.

-Enjoy!
