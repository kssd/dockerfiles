# Plex Mediaserver : Docker Image

Dockerfile to set up (Plex Media Server)[https://plex.tv/]

Instructions to run:

```sh
docker run -d -h *host_name* -v /*config_location*:/config -v /*videos_location*:/data -p 32400:32400 plex
```
or for auto detection to work add --net="host". Though be aware this more insecure and not best practice with docker images.

See https://docs.docker.com/articles/networking/#how-docker-networks-a-container

```sh
docker run -d --net="host" -v /*config_location*:/config -v /*videos_location*:/data -p 32400:32400 plex
```

The first time it runs, it will initialize the config directory and terminate. (This most likely won't happen if you've used the --net="host")

You will need to modify the auto-generated config file to allow connections from your local IP range (This should not be needed if you've used the --net="host"). This can be done by modifying the file:

*config_location*/Library/Application Support/Plex Media Server/Preferences.xml

and adding ```allowedNetworks="192.168.1.0/255.255.255.0" ``` as a parameter in the <Preferences ...> section. (Or what ever your local range is)

Start the docker instance again and it will stay as a daemon and listen on port 32400.

Browse to: ```http://*ipaddress*:32400/web``` to run through the setup wizard.

