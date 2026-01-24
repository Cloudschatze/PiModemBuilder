#!/bin/bash
clear
echo "PiModem Builder v0.1"
echo "--------------------"

echo -n "Installing prerequisites..."
if sudo apt-get update --allow-releaseinfo-change > /dev/null 2>&1 \
&& sudo apt-get install -y iptables ppp telnet xinetd telnetd-ssl > /dev/null 2>&1 \
&& cd /tmp \
&& wget https://github.com/FozzTexx/tcpser/archive/refs/heads/master.zip > /dev/null 2>&1 \
&& unzip -o master.zip > /dev/null 2>&1 \
&& cd tcpser-master \
&& make > /dev/null 2>&1 \
&& sudo cp -p tcpser /usr/local/bin > /dev/null 2>&1; then
    echo "Done"
else
    echo "Failed"
    exit 1
fi

echo -n "Enabling Network Address Translation and IPv4 port-forwarding..."
if sudo debconf-set-selections << 'EOF'
iptables-persistent iptables-persistent/autosave_v4 boolean true
iptables-persistent iptables-persistent/autosave_v6 boolean false
EOF
then
    if sudo iptables -t nat -A POSTROUTING -o wlan0 -j MASQUERADE > /dev/null 2>&1 \
    && sudo apt-get install -y iptables-persistent > /dev/null 2>&1 \
    && sudo bash -c 'sed -i "/^#*.*net.ipv4.ip_forward/c\net.ipv4.ip_forward = 1" /etc/sysctl.conf || echo "net.ipv4.ip_forward = 1" >> /etc/sysctl.conf' \
    && sudo sysctl -p > /dev/null 2>&1; then
        echo "Done"
    else
        echo "Failed"
        exit 1
    fi
else
    echo "Failed"
    exit 1
fi

echo -n "Creating TCPSER startup scripts..."
sudo tee /usr/local/bin/start_tcpser.sh > /dev/null << 'EOF'
#!/bin/bash

phonebook="/home/pi/phonebook.txt"
baud='9600'
dev='/dev/ttyUSB0'

for i in $(cat $phonebook); do
        n="$n -n$i "
done

/usr/local/bin/tcpser -s ${baud} -d ${dev} $n
EOF
sudo tee /etc/systemd/system/tcpser.service > /dev/null << 'EOF'
[Unit]
Description=Modem emulator tcpser
After=network.target

[Service]
Type=simple
User=pi
WorkingDirectory=/usr/local/bin
ExecStart=/usr/local/bin/start_tcpser.sh
Restart=on-abort

[Install]
WantedBy=multi-user.target
EOF
sudo tee /home/pi/phonebook.txt > /dev/null << 'EOF'
5551000=bbs.fozztexx.com
5551001=particlesbbs.dyndns.org:6400
5559000=localhost:2323
EOF
if sudo chmod 755 /usr/local/bin/start_tcpser.sh \
&& sudo systemctl daemon-reload \
&& sudo systemctl enable tcpser  > /dev/null 2>&1 \
&& sudo systemctl start tcpser > /dev/null 2>&1; then
    echo "Done"
else
    echo "Failed"
    exit 1
fi

echo -n "Creating quick config helper..."
sudo tee /usr/local/bin/pimodem-baud > /dev/null << 'EOF'
#!/bin/bash

if [ -z "$1" ]; then
    echo "Current baud rate setting:"
    grep "baud=" /usr/local/bin/start_tcpser.sh | head -1
    echo
    echo "Usage: pimodem-baud <rate>"
    echo "Example: pimodem-baud 2400"
    echo
    echo "Common rates: 300, 1200, 2400, 9600, 19200, 38400"
    exit 1
fi

echo "Changing baud rate to: $1"

# Update the baud rate in the script
if sudo sed -i "s/baud='[0-9]*/baud='$1/" /usr/local/bin/start_tcpser.sh; then
    echo "Configuration updated successfully"
    
    # Restart tcpser service
    echo "Restarting tcpser service..."
    if sudo systemctl restart tcpser; then
        echo "tcpser restarted successfully"
        
        # Show status
        sleep 2
        echo
        echo "Service status:"
        sudo systemctl --no-pager status tcpser
    else
        echo "Warning: Failed to restart tcpser service"
        exit 1
    fi
else
    echo "Error: Failed to update configuration"
    exit 1
fi
EOF

if sudo chmod 755 /usr/local/bin/pimodem-baud; then
    echo "Done"
else
    echo "Failed"
    exit 1
fi

echo -n "Creating ppp user..."
if sudo useradd -m ppp > /dev/null 2>&1 \
&& sudo usermod -aG dip ppp > /dev/null 2>&1 \
&& sudo usermod -s /usr/sbin/pppd ppp > /dev/null 2>&1 \
&& sudo touch /home/ppp/.hushlogin > /dev/null 2>&1 \
&& sudo loginctl enable-linger pi ppp; then
    echo "Done"
else
    echo "Failed"
    exit 1
fi

echo -n "Creating pppd configuration..."
sudo mv /etc/ppp/options /etc/ppp/options.orig > /dev/null 2>&1
sudo mv /etc/ppp/pap-secrets /etc/ppp/pap-secrets.orig > /dev/null 2>&1
sudo tee /etc/ppp/options > /dev/null << 'EOF'
# We will be doing PPP over Telnet - disable serial control.
local

# Terminate connection if remote side stops responding.
lcp-echo-interval 30
lcp-echo-failure 4

# Debug adds a lot of detail into the system logs regarding PPP negotiation.
# This is helpful in debugging client issues.
#debug

# IP addresses to use in local:remote format.  We use NAT to share
# the Wi-Fi connection, make sure these are outside of your real subnet.
192.192.1.1:192.192.1.2

# Other sensible options
asyncmap 0
passive
noipx
noauth
EOF
sudo tee /etc/ppp/pap-secrets > /dev/null << 'EOF'
# Allow any username/password
*	*	""	*
EOF
sudo tee /etc/xinetd.d/pppd > /dev/null << 'EOF'
service pppd
{
    type = UNLISTED
    flags  = REUSE
    socket_type = stream
    wait  = no
    user  = root
    server  = /usr/sbin/in.telnetd
    server_args = -h -L /usr/local/bin/ppplogin
    disable  = no
    bind  = 127.0.0.1
    port = 2323
}
EOF
sudo tee /usr/local/bin/ppplogin > /dev/null << 'EOF'
#!/bin/bash
/bin/login -f ppp
EOF
if sudo chmod 755 /usr/local/bin/ppplogin \
&& sudo systemctl enable xinetd > /dev/null 2>&1 \
&& sudo systemctl restart xinetd > /dev/null 2>&1; then
    echo "Done"
else
    echo "Failed"
    exit 1
fi
echo -n "Verifying services..."
if systemctl is-active --quiet tcpser && systemctl is-active --quiet xinetd; then
    echo "Done"
else
    echo "Warning: Some services may not be running"
fi
echo
echo "PiModem setup complete!"
echo
echo "Default baud rate: 9600 (good for most retro systems)"
echo
echo "To change baud rate if needed/desired:"
echo "  pimodem-baud <rate>"
echo
echo "Examples:"
echo "  pimodem-baud 2400   # Change to 2400 baud"
echo "  pimodem-baud 19200  # Change to 19200 baud"
echo "  pimodem-baud        # Show current setting"
echo
echo "Common rates: 300, 1200, 2400, 9600, 19200, 38400"
echo
echo "Check status anytime: sudo systemctl status tcpser"
echo
