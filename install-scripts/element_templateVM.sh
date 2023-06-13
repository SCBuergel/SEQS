echo "Installing element chat"

curl --proxy 127.0.0.1:8082 -s https://packages.element.io/debian/element-io-archive-keyring.gpg | sudo tee /usr/share/keyrings/element-io-archive-keyring.gpg >> /dev/null
echo "deb [signed-by=/usr/share/keyrings/element-io-archive-keyring.gpg] https://packages.element.io/debian/ default main" | sudo tee /etc/apt/sources.list.d/element-io.list

sudo apt update

sudo apt install element-desktop -y
