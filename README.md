# empyrion-server (Pterodactyl Image Fork)

This is a fork of the Empyrion Docker Image, changed to work with Pterodactyl.

# Installation of the egg:
Navigate to your Empyrion Panel and open the Nests section.
Create a new Nest and give it a fancy name, or select an existing one.
Download the egg .json file found on this page and upload it.

Now head over to Servers --> Create

You have a variety of settings that you can set, configure how you like.

Make sure to give it the ports 30000, 30001, 30002, 30003.
You may add the port 30004 for Telnet access, but please add a password to protect it.

# Additional stuff I added:
## Options
I added a bunch of options that you can configure while creating the server, or in the server panel in the Startup section.
I added a bunch of comments to hopefully explain it far enough.

## Console that accepts commands
I made it so that the console connects via a telnet session to the server while still showing the logs.
That way, you can use console commands instead of only being able to read the logs.
However, for this functionality, you have to enable Telnet in the options.
It will automaticly take the password from the options.
You dont need to set a password as long as you dont assign the port 30004, which exposes it to the internet or that network.

## SteamCMD Account Login for Workshop downloads
You can enable to login with SteamCMD in order to be able to download Workshop contents.
However, **DO NOT LOG IN WITH YOUR PERSONAL STEAM ACCOUNT, AS LOGIN CREDENTIALS ARE SAVED IN PLAIN TEXT!**.
Some games require to be logged in, in order to download and run the server or download workshop contents.
You can create a new account for the server and share access via Family Sharing. With free games, you will have to log in and add them to the library before SteamCMD can access it.

## How to add Workshop Content (Scenarios)
The Server uses this directory for the Scenarios:
`/home/container/Steam/steamapps/common/Empyrion - Dedicated Server/Content/Scenarios/`

You can download Scenarios and upload them here.
Make sure to set the name in the Option Scenario Name in the server settings, to match the name of the folder in this directory.

### Scenarios downloaded over SteamCMD Workshop
Before the server can access the Scenario that was downloaded via the SteamCMD Workshop, you have to navigate to:
`/home/container/Steam/steamapps/workshop/content/`
Here you will now find your downloaded Scenario(s), they will be named after their workshop id.

Now enter that directory, you will find another folder inside with some numbers. Move this file over to `/home/container/Steam/steamapps/common/Empyrion - Dedicated Server/Content/Scenarios/` and rename it to the Scenario name. (I think it only has to match with the Server Scenario Name option.)
In Pterodactyl, you can paste this in the move option to make things easier for you:
`../../../common/Empyrion - Dedicated Server/Content/Scenarios/SCENARIONAME`

Make sure to rename SCENARIONAME with the name of the Scenario.

And yeah, set the same name in the Scenario Name option and your Scenario is installed.

## Use Panel Config Option
This option toggles wether the server will use the dedicated.yaml file, or the dedicated-generated.yaml file.
When you make changes to the server settings within the Pterodactyl panel, which you can find in the startup section, it writes those changes to the dedicated-generated.yaml file on each boot.
You can disable this (which removes the server launch option to use that file), if you prefer to make manual changes to the config file, or you wish to change an option that isnt covered by the settings.
Just for your information: You can still enable Telnet and set the password and port to match what you have configured in the dedicated.yaml, to have the console commands feature, even when the Use Panel Config Option is disabled.

Also, even if this option is disabled, the file will still be updated on each boot. So if you want to make manual changes, you can still copy and paste the contents of the dedicated-generated.yaml file to make the initial creation easier / have a more user friendly config generation.

### Yeah I think thats mostly it. I hope this makes things easier for you, and I'm open for suggestions (tho its unlikely I will change much here until it breaks and stops working for me).

## Below is the original description of the docker container, tho most of it isnt of much interest.

**Docker image for the [Empyrion](https://empyriongame.com/) dedicated server using WINE**

This Docker image includes WINE and steamcmd, along with an entrypoint script that bootstraps the Empyrion dedicated server installation via steamcmd.

## Breaking changes
The entrypoint no longer `chown`'s the Steam directory, so make sure to run the container as a user with appropriate permissions.

## Usage

### Basic setup
1. Create a directory for your game data:
    ```sh
    mkdir -p gamedir
    ```
2. Run the Docker container:
    ```sh
    docker run -d -p 30000:30000/udp --restart unless-stopped -v $PWD/gamedir:/home/user/Steam bitr/empyrion-server
    ```

### Running the experimental version
1. Create a directory for your beta game data:
    ```sh
    mkdir -p gamedir_beta
    ```
2. Run the Docker container with the `BETA` environment variable set to 1:
    ```sh
    docker run -di -p 30000:30000/udp --restart unless-stopped -v $PWD/gamedir_beta:/home/user/Steam -e BETA=1 bitr/empyrion-server
    ```

## Permission errors
If you're getting permission errors, it's because the folder you mounted in with `-v` didn't already exist and is now created and owned by **root:root**. You need to `chown` the volume mount to **1000:1000** (unless you've specified otherwise when you ran the `docker` command)

## Configuration
After starting the server, you can edit the **dedicated.yaml** file located at **gamedir/steamapps/common/Empyrion - Dedicated Server/dedicated.yaml**. You will need to restart the Docker container after making changes.

The **DedicatedServer** folder is symlinked to **/server**, allowing you to refer to saves with **z:/server/Saves**. For example, for a save called **The_Game**:
```sh
# Run the container with the specific save
docker run -d -p 30000:30000/udp --restart unless-stopped -v $PWD/gamedir:/home/user/Steam bitr/empyrion-server -- -dedicated 'z:/server/Saves/Games/The_Game/dedicated.yaml'
```

## Advanced Usage
To append arguments to the `steamcmd` command, use the `STEAMCMD` environment variable. For example:
```sh
-e "STEAMCMD=+runscript /home/user/Steam/add_scenario.txt"
```

So to add a scenario, you'd add the following to `$PWD/gamedir/add_scenario.txt`:

```
workshop_download_item 383120 <workshop_id>
```

Look for multiplayer scenarios at https://steamcommunity.com/workshop/browse?appid=383120 and use the workshop id (available in the browser url when configuring which scenario to add)

## Additional Information
For more information about setting up the Empyrion dedicated server, refer to the [wiki](https://empyrion.gamepedia.com/Dedicated_Server_Setup).

