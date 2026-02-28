# Recipe Image Converter: Now for Windows, macOS, and Linux

This tool automatically turns pictures of your recipes into organized digital text, ready for import into services like Plan to Eat. It reads the text from your images, uses AI to understand and structure the recipe details (like ingredients, directions, and prep time), and even estimates nutritional information. Thanks to PowerShell 7, this script now runs on Windows, macOS, and Linux.

## Features

* **Cross-Platform:** Works on Windows, macOS, and Linux.
* **Automatic Grouping:** Intelligently groups multiple photos of the same recipe together.
* **AI-Powered Text Recognition:** Extracts text from your images, even if they are messy screenshots.
* **Smart Data Extraction:** Identifies the title, ingredients, directions, prep time, and more.
* **Nutritional Estimates:** Calculates estimated nutritional facts per serving.
* **Flexible Export:** Creates a `recipes.csv` file for generic imports, a batch text file specifically for Plan to Eat, and can optionally save individual `.txt` files for each recipe.

## Getting Started: One-Time Setup

Before you can use the script, you need to set up a few things on your computer. You only have to do this once.

### 1. Install PowerShell 7

This script requires a modern, cross-platform version of PowerShell.

**On Windows**

1. Go to the official [PowerShell GitHub releases page](https://github.com/PowerShell/PowerShell/releases/latest).
2. Scroll down to the "Assets" section.
3. Download the file that ends with `-win-x64.msi`. For example: `PowerShell-7.4.2-win-x64.msi`.
4. Run the downloaded installer and accept all the default options.

**On macOS**

The easiest way to install PowerShell on macOS is using [Homebrew](https://brew.sh/).

1. Open the **Terminal** app.
2. If you don't have Homebrew installed, paste this command and press Enter:
   ```bash
   /bin/bash -c "$(curl -fsSL [https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh](https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh))"
   ```
3. Once Homebrew is ready, install PowerShell:
   ```bash
   brew install --cask powershell
   ```
Alternatively, you can download the `.pkg` installer directly from the [PowerShell GitHub releases page](https://github.com/PowerShell/PowerShell/releases/latest).

**On Linux**

Installation methods vary by distribution (like Ubuntu, Debian, or Fedora). Most modern package managers include a `powershell` package.

For example, on **Ubuntu**, you can install it using `snap`:
```bash
sudo snap install powershell --classic
```
For other distributions and detailed instructions, please refer to the official [Microsoft documentation for installing PowerShell on Linux](https://learn.microsoft.com/en-us/powershell/scripting/install/installing-powershell-on-linux).

### 2. Get an OpenAI API Key

The script uses OpenAI's AI to understand your recipes. This requires a personal "API Key".

1. Go to the [OpenAI API Keys page](https://platform.openai.com/account/api-keys) and log in or create an account.
2. Click the "**+ Create new secret key**" button.
3. Give the key a name (like "Recipe Script") and click "Create secret key".
4. **Important:** Copy the key immediately and save it somewhere safe, like a text editor. You will not be able to see it again.

*Note: Using the OpenAI API may incur small costs. They typically provide a free starting credit, but be sure to check their current pricing.*

### 3. Create the Configuration File

You need to tell the script what your API key is. This step is the same for all operating systems.

1. In the same folder where you saved the `Process-Recipe.ps1` script, create a new file named exactly `.env` (the dot at the beginning is important).
2. Open the `.env` file with a plain text editor (like Notepad on Windows, TextEdit on macOS, or Gedit on Linux) and add the following line, pasting your own API key after the equals sign:
   ```
   $apiKey="sk-YOUR_API_KEY_HERE"
   ```
3. Save and close the file.

## How to Use the Script

### Step 1: Organize Your Recipe Photos

Place all the recipe images you want to process into a single folder on your computer.

* **Windows Example:** `C:\Users\YourUser\Documents\Recipes`
* **macOS Example:** `/Users/yourusername/Documents/Recipes`
* **Linux Example:** `/home/yourusername/Documents/Recipes`

### Step 2: Open PowerShell 7

* **Windows:** Click the Start Menu, type `pwsh`, and press Enter.
* **macOS & Linux:** Open your **Terminal** app, type `pwsh`, and press Enter.

You'll know you're in PowerShell when the command prompt changes to start with `PS`.

### Step 3: Navigate to the Script's Folder

Tell PowerShell where the script is located using the `cd` (Change Directory) command.

* **Windows Example:**
  ```powershell
  cd C:\Users\YourUser\Documents\recipe-converter
  ```
* **macOS Example:**
  ```powershell
  cd /Users/yourusername/Documents/recipe-converter
  ```
* **Linux Example:**
  ```powershell
  cd /home/yourusername/recipe-converter
  ```

### Step 4: Run the Script

Now you can run the script. The basic command points to the folder with your recipe photos. Note the slight difference in how you run scripts on Windows vs. macOS/Linux.

**Basic Example:**

* **Windows:**
  ```powershell
  .\Process-Recipe.ps1 -Path "C:\Users\YourUser\Documents\Recipes"
  ```
* **macOS/Linux:**
  ```powershell
  ./Process-Recipe.ps1 -Path "/Users/yourusername/Documents/Recipes"
  ```

**Example with Plain Text Files:**
To also get a separate `.txt` file for each recipe, add the `-SaveAsPlainText` flag.
```powershell
./Process-Recipe.ps1 -Path "/path/to/your/Recipes" -SaveAsPlainText
```

**Example with PlanToTeach Batch Text File:**
To also get a separate `.txt` file that includes a batch of recipes for import to PlanToEat, use `-SaveAsPlanToEatBatchFile`.
```powershell
./Process-Recipe.ps1 -Path "/path/to/your/Recipes" -SaveAsPlanToEatBatchFile
```

**Example with Tags:**
To add "new" and "dessert" to every recipe, use `-BatchTags`.
```powershell
./Process-Recipe.ps1 -Path "/path/to/your/Recipes" -BatchTags "Family, Grandma"
```


## Troubleshooting

- **"API Key" Errors:** Double-check that your `.env` file is named correctly and the API key inside is correct.
- **"Command not found" Error (macOS/Linux):** If you get an error like `./Process-Recipe.ps1: command not found`, you may need to make the script executable. Run this command once: `chmod +x ./Process-Recipe.ps1`.
- **"ThreadJob" Errors:** Make sure you installed PowerShell 7 correctly and are running it (the command is `pwsh`, not `powershell`).
- **See More Detail:** If something isn't working, run the script with the `-Verbose` flag to see every step it's taking.
  ```powershell
  ./Process-Recipe.ps1 -Path "/path/to/your/Recipes" -Verbose
