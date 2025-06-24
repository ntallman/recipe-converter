# Recipe Image Converter

This tool automatically turns pictures of your recipes into organized digital text, ready for import into services like Plan to Eat. It reads the text from your images, uses AI to understand and structure the recipe details (like ingredients, directions, and prep time), and even estimates nutritional information.

## Features

-   **Automatic Grouping:** Intelligently groups multiple photos of the same recipe together.
-   **AI-Powered Text Recognition:** Extracts text from your images, even if they are messy screenshots.
-   **Smart Data Extraction:** Identifies the title, ingredients, directions, prep time, and more.
-   **Nutritional Estimates:** Calculates estimated nutritional facts per serving.
-   **Flexible Export:** Creates a `recipes.csv` file for easy import into recipe managers and can optionally save individual `.txt` files for each recipe.

## Getting Started: One-Time Setup

Before you can use the script, you need to set up a few things on your computer. You only have to do this once.

### 1. Install PowerShell 7

This script requires a modern version of PowerShell.

1.  Go to the official PowerShell GitHub page.
2.  Scroll down to the "Assets" section.
3.  Download the file that ends with `-win-x64.msi`. For example: `PowerShell-7.4.2-win-x64.msi`.
4.  Run the downloaded installer and accept all the default options.

### 2. Get an OpenAI API Key

The script uses OpenAI's AI to understand your recipes. This requires a personal "API Key".

1.  Go to the OpenAI API Keys page and log in or create an account.
2.  Click the "**+ Create new secret key**" button.
3.  Give the key a name (like "Recipe Script") and click "Create secret key".
4.  **Important:** Copy the key immediately and save it somewhere safe, like Notepad. You will not be able to see it again.

*Note: Using the OpenAI API may incur small costs. They typically provide a free starting credit, but be sure to check their current pricing.*

### 3. Create the Configuration File

You need to tell the script what your API key is.

1.  In the same folder where you saved `Process-Recipe.ps1`, create a new text file.
2.  Name this file exactly `.env` (the dot at the beginning is important). Windows might warn you about this; it's okay.
3.  Open the `.env` file with Notepad and add the following line, pasting your own API key after the equals sign:

    ```
    $apiKey="sk-YOUR_API_KEY_HERE"
    ```
4.  Save and close the file.

## How to Use the Script

### Step 1: Organize Your Recipe Photos

Place all the recipe images you want to process into a single folder on your computer. For example, `C:\MyRecipes`.

### Step 2: Open PowerShell 7

1.  Click the Windows Start Menu.
2.  Type `pwsh` and press Enter.
3.  A blue or black window will appear. This is the PowerShell terminal.

### Step 3: Navigate to the Script's Folder

You need to tell PowerShell where the script is located. Use the `cd` (Change Directory) command.

For example, if you saved the script in `C:\Users\john\recipe-converter`, you would type the following and press Enter:

```powershell
cd C:\Users\john\recipe-converter
```

### Step 4: Run the Script

Now you can run the script. The basic command points to the folder with your recipe photos.

**Basic Example:**
This command will process all images in the `C:\MyRecipes` folder.

```powershell
.\Process-Recipe.ps1 -Path "C:\MyRecipes"
```

**Example with Plain Text Files:**
If you also want a separate `.txt` file for each recipe, add the `-SaveAsPlainText` flag.

```powershell
.\Process-Recipe.ps1 -Path "C:\MyRecipes" -SaveAsPlainText
```

**Example with Tags:**
To add the tags "new" and "dessert" to every recipe in this batch, use `-BatchTags`.

```powershell
.\Process-Recipe.ps1 -Path "C:\MyRecipes" -BatchTags "new,dessert"
```

## Understanding the Output

-   **`recipes.csv`:** This file will be created in the same folder as your images. You can import it directly into services like Plan to Eat.
-   **`text` folder:** If you used `-SaveAsPlainText`, this subfolder will be created containing a nicely formatted text file for each recipe.
-   **On-Screen Report:** The script will tell you how many recipes were processed successfully and how many were skipped (e.g., because the image was not a recipe).

## Troubleshooting

-   **Errors about "API Key":** Double-check that your `.env` file is named correctly and that the API key inside it is correct.
-   **Errors about "ThreadJob":** If you see an error about `Start-ThreadJob`, make sure you installed PowerShell 7 correctly and are running it (the icon is a darker blue/black circle, not the lighter blue square of the older Windows PowerShell).
-   **To see more detail:** If something isn't working, you can run the script with the `-Verbose` flag to see every step it's taking. This can help identify the problem.
    ```powershell
    .\Process-Recipe.ps1 -Path "C:\MyRecipes" -Verbose
    ```