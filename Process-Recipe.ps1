<#
.SYNOPSIS
    A script to process recipe images, automatically detecting and grouping related images, confirming they are recipes with a two-pass verification system, generating structured data, and exporting it all to a single CSV file formatted for import into Plan to Eat.

.DESCRIPTION
    This script takes an image file or a directory of image files as input. The recipe detection logic has been upgraded to perform a second, more detailed analysis if the first check is negative, reducing false negatives. It uses a sophisticated job manager to process recipes in parallel. This feature requires PowerShell 7 or newer. This version includes a sanitization step to convert special characters (e.g., ½, —, “) to standard ASCII equivalents (e.g., 1/2, -, ").

.PARAMETER Path
    The path to a single image file or a directory containing image files.

.PARAMETER ThrottleLimit
    The maximum number of recipe groups to process in parallel at any given time. Defaults to 5.

.PARAMETER BatchTags
    A comma-separated string of tags to be added to every processed recipe in the batch.

.PARAMETER SaveAsPlainText
    If specified, the script will save a formatted plain text file for each successfully processed recipe in a 'text' sub-folder.

.EXAMPLE
    .\Process-Recipes.ps1 -Path "C:\Users\YourUser\Documents\Recipes" -BatchTags "new, from-phone" -SaveAsPlainText
#>
[CmdletBinding()]
param (
    [Parameter(Mandatory = $true)]
    [string]$Path,
    [int]$ThrottleLimit = 5,
    [string]$BatchTags,
    [switch]$SaveAsPlainText
)

Write-Verbose "--- SCRIPT START ---"
Write-Verbose "Parameter -Path: $Path"
Write-Verbose "Parameter -ThrottleLimit: $ThrottleLimit"
Write-Verbose "Parameter -BatchTags: $BatchTags"
Write-Verbose "Parameter -SaveAsPlainText: $($SaveAsPlainText.IsPresent)"
Write-Verbose "--------------------"

# --- CONFIGURATION ---
# IMPORTANT: This script uses the $apiKey variable sourced from your .env file.
#$apiKey = ""
. .\.env

# Grouping Settings
$maxTimeBetweenShots = 7
$maxRetries = 3
$retryInitialDelayMs = 1500
Write-Verbose "Configuration - Max time between shots: $maxTimeBetweenShots seconds"
Write-Verbose "Configuration - Max API retries: $maxRetries"
# ---------------------


# --- SCRIPT ---

if ($PSVersionTable.PSVersion.Major -lt 7) {
    Write-Error "PowerShell 7 or newer is required for this script."; exit
}
if (-not (Get-Command Start-ThreadJob -ErrorAction SilentlyContinue)) {
    Write-Error "The ThreadJob module is required. Please run 'Install-Module -Name ThreadJob' in an elevated PowerShell console."; exit
}

function Get-TimestampFromFile($File) {
    $match = [regex]::Match($File.Name, '(\d{8}_\d{6})')
    if ($match.Success) { try { return [datetime]::ParseExact($match.Groups[1].Value, "yyyyMMdd_HHmmss", $null) } catch { return $File.CreationTime } }
    return $File.CreationTime
}

# --- MAIN LOGIC ---

# --- Stage 1: Group Images by Timestamp ---
Write-Host "Finding and grouping images..."
if (Test-Path -Path $Path -PathType Leaf) { $imageFiles = @(Get-Item $Path) }
elseif (Test-Path -Path $Path -PathType Container) { $imageFiles = Get-ChildItem -Path $Path -Include *.jpg, *.jpeg, *.png, *.gif, *.bmp -Recurse | Sort-Object Name }
else { Write-Error "The path '$Path' is not a valid file or directory."; exit }
if ($imageFiles.Count -eq 0) { Write-Warning "No image files found in the specified path."; exit }
Write-Verbose "Found $($imageFiles.Count) total image files."

$outputDirectory = Split-Path -Path $imageFiles[0].FullName -Parent
$csvFilePath = Join-Path -Path $outputDirectory -ChildPath "recipes.csv"
if (Test-Path -Path $csvFilePath) {
    $title = "Confirm Deletion"
    $message = "The output file '$csvFilePath' already exists. Do you want to delete it and continue?"
    $choices = [System.Management.Automation.Host.ChoiceDescription[]]@(
        New-Object System.Management.Automation.Host.ChoiceDescription("&Yes", "Deletes the existing file and continues processing.")
        New-Object System.Management.Automation.Host.ChoiceDescription("&No", "Exits the script without making changes.")
    )
    $decision = $Host.UI.PromptForChoice($title, $message, $choices, 1) # Default to No

    if ($decision -eq 0) { # User selected "Yes"
        Write-Host "Deleting existing file..." -ForegroundColor Yellow
        try { Remove-Item -Path $csvFilePath -Force; Write-Host "File deleted. Continuing..." } catch { Write-Error "Could not delete existing file '$csvFilePath'. Please delete it manually and try again. `nError: $_"; exit }
    } else { # User selected "No" or closed the prompt
        Write-Error "Operation cancelled by user. The existing file '$csvFilePath' will not be overwritten."; exit
    }
}

$recipeGroups = [System.Collections.Generic.List[object]]::new()
$i = 0
while ($i -lt $imageFiles.Count) {
    $firstFileInGroup = $imageFiles[$i]
    $imageGroup = [System.Collections.Generic.List[psobject]]::new(); $imageGroup.Add($firstFileInGroup)
    $lastTimestamp = Get-TimestampFromFile -File $firstFileInGroup; $j = $i + 1
    Write-Verbose "Starting new group with $($firstFileInGroup.Name)"
    while ($j -lt $imageFiles.Count) {
        $nextFile = $imageFiles[$j]; $nextTimestamp = Get-TimestampFromFile -File $nextFile
        $timeDifference = New-TimeSpan -Start $lastTimestamp -End $nextTimestamp
        if ($timeDifference.TotalSeconds -gt 0 -and $timeDifference.TotalSeconds -le $maxTimeBetweenShots) {
            $imageGroup.Add($nextFile); $lastTimestamp = $nextTimestamp; $j++
        } else { break }
    }
    Write-Verbose "Finalized group with $($imageGroup.Count) image(s)."
    $recipeGroups.Add($imageGroup)
    $i = $j
}

# --- Stage 2: Process Groups in Parallel using Start-ThreadJob ---
Write-Host "Found $($recipeGroups.Count) recipe groups. Starting parallel processing..."

$scriptBlock = {
    param($imageGroup, $apiKey, $maxRetries, $retryInitialDelayMs, $BatchTags, $local:VerbosePreference)

    $groupFileNamesForReport = $imageGroup | ForEach-Object { $_.Name } | Join-String -Separator ", "
    Write-Verbose "THREAD [$( [System.Threading.Thread]::CurrentThread.ManagedThreadId )]: Starting processing for group: $groupFileNamesForReport"

    # --- Helper Functions for the Job ---
    function Convert-ImageToBase64 { param ([string]$ImagePath) try { return [System.Convert]::ToBase64String([System.IO.File]::ReadAllBytes($ImagePath)) } catch { return $null } }

    function Invoke-OpenAiApi {
        param([string]$Uri, [hashtable]$Headers, [string]$Body, [string]$ApiCallType, [int]$MaxRetries, [int]$RetryInitialDelayMs)
        Write-Verbose "Invoking OpenAI API for '$ApiCallType'."
        $sanitizedUri = $Uri.Trim("[]"); $retries = 0; $delay = $RetryInitialDelayMs
        while ($retries -lt $MaxRetries) {
            $retries++; $response = $null
            try { $response = Invoke-WebRequest -Uri $sanitizedUri -Method Post -Headers $Headers -Body $Body -ContentType "application/json" -SkipHttpErrorCheck } catch { Write-Verbose "API call '$ApiCallType' failed on attempt $($retries). Error: $($_.Exception.Message)"; Start-Sleep -Milliseconds $delay; $delay *= 2; continue }
            if ($response.StatusCode -eq 200) { Write-Verbose "API call '$ApiCallType' successful."; return $response.Content }
            if ($response.StatusCode -eq 429) { Start-Sleep -Milliseconds $delay; $delay *= 2; continue }
            return $null
        }
        Write-Warning "API call '$ApiCallType' failed after $MaxRetries retries."
        return $null
    }

    function Get-OcrTextFromImage {
        param ([string]$base64Image, [string]$ApiKey, [int]$MaxRetries, [int]$RetryInitialDelayMs)
        $headers = @{ "Authorization" = "Bearer $ApiKey" }
        Write-Verbose "Requesting OCR text extraction from API."
        $body = @{ "model" = "gpt-4o"; "messages" = @(@{ "role" = "user"; "content" = @(@{ "type" = "text"; "text" = "Extract all the text from this image." }, @{ "type" = "image_url"; "image_url" = @{ "url" = "data:image/jpeg;base64,$base64Image" } }) }); "max_tokens" = 2000 } | ConvertTo-Json -Depth 10
        $responseJson = Invoke-OpenAiApi -Uri "https://api.openai.com/v1/chat/completions" -Headers $headers -Body $body -ApiCallType "OCR" -MaxRetries $MaxRetries -RetryInitialDelayMs $RetryInitialDelayMs
        if ($responseJson) { return ($responseJson | ConvertFrom-Json).choices[0].message.content }
        return $null
    }

    function Confirm-IsRecipe {
        param ([string]$OcrText, [string]$ApiKey, [int]$MaxRetries, [int]$RetryInitialDelayMs)
        $headers = @{ "Authorization" = "Bearer $ApiKey" }

        # --- First Pass Check ---
        Write-Verbose "Performing first-pass recipe check."
        $prompt1 = 'You are a text classification expert. Your task is to determine if the following text, extracted from a phone or computer screenshot, contains a food recipe. The text may be noisy. Your goal is to find the core content. A food recipe must have at least two of the following three elements: a clear title, a list of ingredients, or preparation steps. Respond with a single, raw JSON object with two keys: "is_recipe" (boolean) and "reason" (a brief explanation). --- Text to analyze: ' + $OcrText
        $body1 = @{ "model" = "gpt-4o"; "messages" = @(@{ "role" = "user"; "content" = $prompt1 }); "max_tokens" = 100; "response_format" = @{ "type" = "json_object" } } | ConvertTo-Json -Depth 10
        $responseJson1 = Invoke-OpenAiApi -Uri "https://api.openai.com/v1/chat/completions" -Headers $headers -Body $body1 -ApiCallType "Recipe Check 1" -MaxRetries $MaxRetries -RetryInitialDelayMs $RetryInitialDelayMs

        $initialResult = if ($responseJson1) { ($responseJson1 | ConvertFrom-Json).choices[0].message.content | ConvertFrom-Json } else { [PSCustomObject]@{ is_recipe = $false; reason = "API call failed during initial recipe check." } }
        Write-Verbose "First-pass result: $($initialResult.is_recipe). Reason: $($initialResult.reason)"
        if ($initialResult.is_recipe) {
            return $initialResult # It's a recipe, no need to double-check
        }

        # --- Second Pass (Double-Check) ---
        Write-Verbose "First-pass was negative. Performing second-pass (double-check)."
        $prompt2 = 'A previous analysis suggested the following text might not be a food recipe. Please take a second, closer look. The text was extracted from a messy screenshot and may be poorly formatted. Re-evaluate the text for any evidence of a recipe, such as a title, a list of ingredients (lines starting with quantities or bullets), or cooking instructions (numbered steps or paragraphs describing a process). Look carefully. Sometimes a recipe is present even if the formatting is poor. Based on your second analysis, is there a food recipe anywhere in this text? Respond with a single, raw JSON object with two keys: "is_recipe" (boolean) and "reason" (a brief, one-sentence explanation for your final decision). --- Text to re-evaluate: ' + $OcrText
        $body2 = @{ "model" = "gpt-4o"; "messages" = @(@{ "role" = "user"; "content" = $prompt2 }); "max_tokens" = 100; "response_format" = @{ "type" = "json_object" } } | ConvertTo-Json -Depth 10
        $responseJson2 = Invoke-OpenAiApi -Uri "https://api.openai.com/v1/chat/completions" -Headers $headers -Body $body2 -ApiCallType "Recipe Check 2" -MaxRetries $MaxRetries -RetryInitialDelayMs $RetryInitialDelayMs

        if ($responseJson2) {
            $finalResult = ($responseJson2 | ConvertFrom-Json).choices[0].message.content | ConvertFrom-Json
            Write-Verbose "Second-pass result: $($finalResult.is_recipe). Reason: $($finalResult.reason)"
            return $finalResult
        }
        return [PSCustomObject]@{ is_recipe = $false; reason = "API call failed during second recipe check." }
    }

    function Get-StructuredRecipeData {
        param ([string]$OcrText, [string]$ApiKey, [int]$MaxRetries, [int]$RetryInitialDelayMs)
        $headers = @{ "Authorization" = "Bearer $ApiKey" }
        $csvHeaders = "'Title', 'Course', 'Cuisine', 'Main Ingredient', 'Description', 'Source', 'Url', 'Url Host', 'Prep Time', 'Cook Time', 'Total Time', 'Servings', 'Yield', 'Ingredients', 'Directions', 'Tags', 'Rating', 'Public Url', 'Photo Url', 'Nutritional Score (generic)', 'Calories', 'Fat', 'Saturated Fat', 'Cholesterol', 'Sodium', 'Sugar', 'Carbohydrate', 'Fiber', 'Protein', 'Cost'"
        Write-Verbose "Requesting structured recipe data from API."
        $prompt = "You are an expert recipe data extractor. Convert the following text into a structured JSON object. Instructions: 1. Title: Your highest priority is to find the existing title from the text. The title is almost always at the very top of the text, often on its own line or as a short, distinct heading. Search the beginning of the text carefully for this title. If you find one, use that exact text. ONLY if you are absolutely certain no title is present, then generate a concise, descriptive title. In either case (found or generated), you must append a single, relevant food emoji to the very end of the title string. 2. Main Ingredient: Identify the SINGLE most predominant ingredient (e.g., ""Chicken"", ""Beef""). This field MUST NOT contain commas. 3. Rating: The `Rating` field MUST always be an empty string. 4. Other Mandatory Fields: Provide a single value for `Course` and `Cuisine`, and a comma-separated list for `Tags`. 5. Formatting: For `Ingredients` and `Directions`, separate items with `\n`. 6. Sanitization: Convert special characters to standard ASCII. For example, change `½` to `1/2`, `°` to `deg`, and replace em/en dashes with a standard hyphen `-`. 7. Output: Your response MUST be a single, raw JSON object with keys for all of these fields: $($csvHeaders). --- Recipe Text: " + $OcrText
        $body = @{ "model" = "gpt-4o"; "messages" = @(@{ "role" = "user"; "content" = $prompt }); "max_tokens" = 4096; "response_format" = @{ "type" = "json_object" } } | ConvertTo-Json -Depth 10
        $responseJson = Invoke-OpenAiApi -Uri "https://api.openai.com/v1/chat/completions" -Headers $headers -Body $body -ApiCallType "Recipe Structuring" -MaxRetries $MaxRetries -RetryInitialDelayMs $RetryInitialDelayMs
        if ($responseJson) { return ($responseJson | ConvertFrom-Json).choices[0].message.content | ConvertFrom-Json -ErrorAction SilentlyContinue }
        return $null
    }

    function Get-NutritionalData {
        param ([string]$Ingredients, [string]$Servings, [string]$ApiKey, [int]$MaxRetries, [int]$RetryInitialDelayMs)
        if ([string]::IsNullOrWhiteSpace($Ingredients)) { Write-Verbose "Skipping nutritional analysis: No ingredients provided."; return $null }

        $headers = @{ "Authorization" = "Bearer $ApiKey" }
        $nutritionFields = "'Nutritional Score (generic)', 'Calories', 'Fat', 'Saturated Fat', 'Cholesterol', 'Sodium', 'Sugar', 'Carbohydrate', 'Fiber', 'Protein'"
        $servingsText = if (-not [string]::IsNullOrWhiteSpace($Servings)) { $Servings } else { "Not specified, assume 4" }

        Write-Verbose "Requesting nutritional analysis from API based on $($servingsText) servings."
        $prompt = "You are a nutritional analysis expert. Based on the following list of ingredients and the total number of servings, calculate the estimated nutritional information PER SERVING. Provide your answer as a single, raw JSON object. The values should be strings representing the quantity and unit (e.g., '10g', '250mg', '500'). For 'Nutritional Score (generic)', provide a simple score out of 10 (e.g., '7/10'). If you cannot calculate a value for a specific field, use an empty string. Your JSON response must contain keys for all of these fields: $($nutritionFields)."
        $prompt += " --- Ingredients List: `n$($Ingredients)"
        $prompt += " --- Total Servings: $($servingsText)"

        $body = @{ "model" = "gpt-4o"; "messages" = @(@{ "role" = "user"; "content" = $prompt }); "max_tokens" = 500; "response_format" = @{ "type" = "json_object" } } | ConvertTo-Json -Depth 10
        $responseJson = Invoke-OpenAiApi -Uri "https://api.openai.com/v1/chat/completions" -Headers $headers -Body $body -ApiCallType "Nutritional Analysis" -MaxRetries $MaxRetries -RetryInitialDelayMs $RetryInitialDelayMs

        if ($responseJson) {
            Write-Verbose "Successfully received nutritional data from API."
            return ($responseJson | ConvertFrom-Json).choices[0].message.content | ConvertFrom-Json -ErrorAction SilentlyContinue
        }

        return $null
    }

    # --- New Sanitization Function ---
    function Sanitize-String {
        param([string]$InputString)
        if ([string]::IsNullOrWhiteSpace($InputString)) { return "" }

        # This function converts common special characters to their standard ASCII equivalents.
        # It's applied to all string fields returned from the API for data consistency.

        # Character conversions
        $sanitizedString = $InputString.Trim()
        $sanitizedString = $sanitizedString -replace '[\u2018\u2019]', "'"  # Left/Right Single Quotes to Apostrophe
        $sanitizedString = $sanitizedString -replace '[\u201C\u201D]', '"'  # Left/Right Double Quotes to Quotation Mark
        $sanitizedString = $sanitizedString -replace '[\u2013\u2014]', '-'  # En/Em Dash to Hyphen
        $sanitizedString = $sanitizedString -replace '\u2026', '...'      # Ellipsis to three dots
        $sanitizedString = $sanitizedString -replace '°', ' deg '        # Degree Symbol

        # Common Fractions
        $sanitizedString = $sanitizedString -replace '½', '1/2'
        $sanitizedString = $sanitizedString -replace '⅓', '1/3'
        $sanitizedString = $sanitizedString -replace '⅔', '2/3'
        $sanitizedString = $sanitizedString -replace '¼', '1/4'
        $sanitizedString = $sanitizedString -replace '¾', '3/4'
        $sanitizedString = $sanitizedString -replace '⅕', '1/5'
        $sanitizedString = $sanitizedString -replace '⅖', '2/5'
        $sanitizedString = $sanitizedString -replace '⅗', '3/5'
        $sanitizedString = $sanitizedString -replace '⅘', '4/5'
        $sanitizedString = $sanitizedString -replace '⅙', '1/6'
        $sanitizedString = $sanitizedString -replace '⅚', '5/6'
        $sanitizedString = $sanitizedString -replace '⅛', '1/8'
        $sanitizedString = $sanitizedString -replace '⅜', '3/8'
        $sanitizedString = $sanitizedString -replace '⅝', '5/8'
        $sanitizedString = $sanitizedString -replace '⅞', '7/8'

        # Normalize multiple horizontal spaces (spaces, tabs) into a single space, preserving newlines.
        return $sanitizedString -replace '[ \t]+', ' '
    }

    # --- Main Job Logic ---
    $combinedOcrText = [System.Text.StringBuilder]::new()
    foreach ($imageFileInGroup in $imageGroup) {
        Write-Verbose "Processing image: $($imageFileInGroup.Name)"
        $base64Image = Convert-ImageToBase64 -ImagePath $imageFileInGroup.FullName
        if (-not $base64Image) { Write-Warning "Could not convert image to Base64: $($imageFileInGroup.Name)"; continue }
        $ocrText = Get-OcrTextFromImage -base64Image $base64Image -ApiKey $apiKey -MaxRetries $maxRetries -RetryInitialDelayMs $retryInitialDelayMs
        if (-not $ocrText) { Write-Warning "Could not get OCR text for image: $($imageFileInGroup.Name)"; continue }
        Write-Verbose "Extracted $($ocrText.Length) characters of text from $($imageFileInGroup.Name)."
        [void]$combinedOcrText.AppendLine($ocrText)
    }

    if ($combinedOcrText.Length -eq 0) {
        return [PSCustomObject]@{ Status = 'Skipped'; Data = @{ GroupFiles = $groupFileNamesForReport; Reason = "Could not get any text from the images." } }
    }

    Write-Verbose "Combined OCR text length is $($combinedOcrText.Length) characters."
    $ocrTextForNextSteps = $combinedOcrText.ToString()
    $isRecipeResult = Confirm-IsRecipe -OcrText $ocrTextForNextSteps -ApiKey $apiKey -MaxRetries $maxRetries -RetryInitialDelayMs $retryInitialDelayMs
    if (-not $isRecipeResult.is_recipe) {
        return [PSCustomObject]@{ Status = 'Skipped'; Data = @{ GroupFiles = $groupFileNamesForReport; Reason = "[Final Decision] " + $isRecipeResult.reason } }
    }

    $recipeDataObject = Get-StructuredRecipeData -OcrText $ocrTextForNextSteps -ApiKey $apiKey -MaxRetries $maxRetries -RetryInitialDelayMs $retryInitialDelayMs
    Write-Verbose "Successfully structured recipe data. Title: $($recipeDataObject.Title)"
    if (-not $recipeDataObject) {
        return [PSCustomObject]@{ Status = 'Skipped'; Data = @{ GroupFiles = $groupFileNamesForReport; Reason = "Failed to structure recipe data from the combined text." } }
    }

    # Attempt to calculate nutritional data
    $nutritionalInfo = Get-NutritionalData -Ingredients $recipeDataObject.Ingredients -Servings $recipeDataObject.Servings -ApiKey $apiKey -MaxRetries $maxRetries -RetryInitialDelayMs $retryInitialDelayMs
    if ($nutritionalInfo) {
        Write-Verbose "Merging calculated nutritional data into the recipe object."
        # Overwrite the nutritional fields in the main recipe object with the new data
        foreach ($property in $nutritionalInfo.psobject.Properties) {
            if ($recipeDataObject.psobject.Properties[$property.Name]) {
                $recipeDataObject.psobject.Properties[$property.Name].Value = $property.Value
            }
        }
    } else {
        Write-Warning "Could not calculate nutritional data for recipe: $($recipeDataObject.Title)"
    }

    # Apply batch tags if provided
    if (-not [string]::IsNullOrWhiteSpace($BatchTags)) {
        Write-Verbose "Applying batch tags: $BatchTags"
        if ([string]::IsNullOrWhiteSpace($recipeDataObject.Tags)) {
            $recipeDataObject.Tags = $BatchTags
        } else {
            $recipeDataObject.Tags = "$($recipeDataObject.Tags),$BatchTags"
        }
    }

    # Apply sanitization to all string properties of the recipe object
    Write-Verbose "Applying string sanitization to all recipe properties."
    foreach ($property in $recipeDataObject.psobject.Properties) {
        if ($property.Value -is [string]) {
            $property.Value = Sanitize-String -InputString $property.Value
        }
    }
    Write-Verbose "Sanitization complete."

    # Convert title to Title Case if it appears to be in ALL CAPS
    $title = $recipeDataObject.Title
    # Remove emojis and trim whitespace for a more reliable check
    $titleForChecking = ($title -replace "[\uD800-\uDBFF][\uDC00-\uDFFF]", "").Trim()

    # Check if the text part of the title contains an uppercase letter AND no lowercase letters.
    if (($titleForChecking -cmatch '[A-Z]') -and ($titleForChecking -cnotmatch '[a-z]')) {
        Write-Verbose "Title '$title' appears to be in ALL CAPS. Converting to Title Case."
        # Perform the case conversion on the original title to preserve emojis
        $recipeDataObject.Title = (Get-Culture).TextInfo.ToTitleCase($title.ToLower())
        Write-Verbose "New title: $($recipeDataObject.Title)"
    }

    Write-Verbose "THREAD [$( [System.Threading.Thread]::CurrentThread.ManagedThreadId )]: Finished processing group successfully."
    return [PSCustomObject]@{ Status = 'Success'; Data = $recipeDataObject }
}

$jobs = @()
foreach ($group in $recipeGroups) {
    while (@(Get-Job -State Running).Count -ge $ThrottleLimit) {
        Write-Verbose "Throttle limit ($ThrottleLimit) reached. Waiting for a job to complete..."
        Start-Sleep -Seconds 1
    }
    $job = Start-ThreadJob -ScriptBlock $scriptBlock -ArgumentList @($group, $apiKey, $maxRetries, $retryInitialDelayMs, $BatchTags, $VerbosePreference)
    $jobs += $job
}

Write-Host "All $($jobs.Count) jobs launched. Waiting for processing to complete..."
$totalJobs = $jobs.Count
$completedJobCount = 0
while ($completedJobCount -lt $totalJobs) {
    $terminalStates = @('Completed', 'Failed', 'Stopped')
    $completedJobCount = ($jobs | Where-Object { $terminalStates -contains $_.State }).Count
    $percent = if ($totalJobs -gt 0) { [int](($completedJobCount / $totalJobs) * 100) } else { 100 }
    $status = "Completed: $completedJobCount of $totalJobs"
    Write-Progress -Activity "Processing Recipes" -Status $status -PercentComplete $percent
    Start-Sleep -Seconds 1
}
Write-Progress -Activity "Processing Recipes" -Completed

# Wait for all jobs and collect results
Write-Verbose "All jobs have completed. Collecting results..."
$results = $jobs | Receive-Job -Wait
$jobs | Remove-Job
Write-Verbose "Results collected and jobs cleaned up."

# --- Stage 3: Finalize and Export ---
$processedRecipes = $results | Where-Object { $_.Status -eq 'Success' } | Select-Object -ExpandProperty Data
$skippedGroups = $results | Where-Object { $_.Status -eq 'Skipped' } | Select-Object -ExpandProperty Data
Write-Verbose "Processing complete. $($processedRecipes.Count) recipes succeeded, $($skippedGroups.Count) groups were skipped."

# Export to CSV
if ($processedRecipes.Count -gt 0) {
    try {
        $processedRecipes | Export-Csv -Path $csvFilePath -NoTypeInformation -Encoding utf8BOM
        Write-Host "`nSuccessfully created CSV export with $($processedRecipes.Count) recipes: $csvFilePath" -ForegroundColor Green
        Write-Host "The output file is formatted for import into the Plan to Eat recipe manager." -ForegroundColor Cyan
    } catch {
        Write-Error "Failed to create CSV file: $_"
    }
} else {
    Write-Warning "No recipes were successfully processed to create a CSV file."
}

# Export to Plain Text if requested
if ($SaveAsPlainText.IsPresent -and $processedRecipes.Count -gt 0) {
    $txtOutputDirectory = Join-Path -Path $outputDirectory -ChildPath "text"
    if (-not (Test-Path -Path $txtOutputDirectory)) {
        New-Item -Path $txtOutputDirectory -ItemType Directory | Out-Null
    }
    Write-Verbose "Saving plain text files for $($processedRecipes.Count) recipes."
    Write-Host "`nSaving plain text files to: $txtOutputDirectory" -ForegroundColor Cyan

    # Create a reliable map for property names to display names
    $propertyDisplayNames = @{
        'Title' = 'Title'; 'Course' = 'Course'; 'Cuisine' = 'Cuisine'; 'MainIngredient' = 'Main Ingredient';
        'Description' = 'Description'; 'Source' = 'Source'; 'Url' = 'Url'; 'UrlHost' = 'Url Host';
        'PrepTime' = 'Prep Time'; 'CookTime' = 'Cook Time'; 'TotalTime' = 'Total Time';
        'Servings' = 'Servings'; 'Yield' = 'Yield'; 'Tags' = 'Tags'; 'Rating' = 'Rating';
        'PublicUrl' = 'Public Url'; 'PhotoUrl' = 'Photo Url';
        'NutritionalScore(generic)' = 'Nutritional Score (generic)'; 'Calories' = 'Calories';
        'Fat' = 'Fat'; 'SaturatedFat' = 'Saturated Fat'; 'Cholesterol' = 'Cholesterol';
        'Sodium' = 'Sodium'; 'Sugar' = 'Sugar'; 'Carbohydrate' = 'Carbohydrate'; 'Fiber' = 'Fiber';
        'Protein' = 'Protein'; 'Cost' = 'Cost'
    }

    foreach ($recipe in $processedRecipes) {
        # Sanitize title for filename by removing invalid chars and emojis
        $invalidChars = [System.IO.Path]::GetInvalidFileNameChars() -join ''
        $regexInvalidChars = [regex]::Escape($invalidChars)
        $fileName = ($recipe.Title -replace "[\uD800-\uDBFF][\uDC00-\uDFFF]", "").Trim()
        $fileName = ($fileName -replace "[$regexInvalidChars]", "_") + ".txt"
        $filePath = Join-Path -Path $txtOutputDirectory -ChildPath $fileName
        Write-Verbose "Saving text file: $fileName"

        # Build text file content dynamically
        $txtContent = [System.Text.StringBuilder]::new()
        $mainFields = @('Ingredients', 'Directions')

        # Loop through all properties and add them if they have a value
        foreach ($property in $recipe.psobject.Properties) {
            if ($mainFields -contains $property.Name -or [string]::IsNullOrWhiteSpace($property.Value)) {
                continue
            }

            # Use the reliable hashtable for the display name, removing spaces from the property name for the lookup
            $lookupName = $property.Name -replace '\s'
            $displayName = $propertyDisplayNames[$lookupName]
            if ($displayName) {
                [void]$txtContent.AppendLine("${displayName}: $($property.Value)")
            }
        }

        # Add the main multi-line fields with headers
        [void]$txtContent.AppendLine("")
        [void]$txtContent.AppendLine("--- INGREDIENTS ---")
        [void]$txtContent.AppendLine($recipe.Ingredients)
        [void]$txtContent.AppendLine("")
        [void]$txtContent.AppendLine("--- DIRECTIONS ---")
        [void]$txtContent.AppendLine($recipe.Directions)

        try {
            Set-Content -Path $filePath -Value $txtContent.ToString() -Encoding utf8BOM
        } catch {
            Write-Warning "Failed to save plain text file: $filePath. Error: $_"
        }
    }
    Write-Host "Successfully saved $($processedRecipes.Count) plain text recipe files." -ForegroundColor Green
}

# --- Final, Comprehensive Report ---
Write-Verbose "Displaying final report."
Write-Host "`nScript finished."
Write-Host "`n--- Final Processing Report ---" -ForegroundColor Green
Write-Host ("-" * 31)
Write-Host "`nSuccessfully Processed: $($processedRecipes.Count) recipes" -ForegroundColor White
Write-Host "`nSkipped: $($skippedGroups.Count) groups" -ForegroundColor Yellow
if ($skippedGroups.Count -gt 0) {
    foreach ($item in $skippedGroups) {
        Write-Host " - Group Containing:" -NoNewline; Write-Host " $($item.GroupFiles)" -ForegroundColor Cyan
        Write-Host "   Reason:" -NoNewline; Write-Host " $($item.Reason)"
    }
}
Write-Host ("-" * 31) -ForegroundColor Green
