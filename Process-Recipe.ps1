<#
.SYNOPSIS
    A script to process recipe images, automatically detecting and grouping related images, confirming they are recipes with a two-pass verification system, generating structured data, and exporting it all to a single CSV file formatted for import into Plan to Eat.

.DESCRIPTION
    This script takes an image file or a directory of image files as input. The recipe detection logic has been upgraded to perform a second, more detailed analysis if the first check is negative, reducing false negatives. It uses a sophisticated job manager to process recipes in parallel. This feature requires PowerShell 7 or newer.

.PARAMETER Path
    The path to a single image file or a directory containing image files.

.PARAMETER ThrottleLimit
    The maximum number of recipe groups to process in parallel at any given time. Defaults to 5.

.EXAMPLE
    .\Process-Recipes.ps1 -Path "C:\Users\YourUser\Documents\Recipes"
#>
[CmdletBinding()]
param (
    [Parameter(Mandatory = $true)]
    [string]$Path,
    [int]$ThrottleLimit = 5
)

. .\.env

# --- CONFIGURATION ---
# IMPORTANT: Replace "YOUR_OPENAI_API_KEY" with your actual OpenAI API key.
#$apiKey = "sk-9gW0NJp0LxABYPFeTOTU8mSMyG01RI7Swo0r9RTH4HT3BlbkFJes5AHL3uBaGZGgiaWHJzSIUo2wyAIh-tlGsbH2KN0A"

# Grouping Settings
$maxTimeBetweenShots = 8
$maxRetries = 3
$retryInitialDelayMs = 1500
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
    while ($j -lt $imageFiles.Count) {
        $nextFile = $imageFiles[$j]; $nextTimestamp = Get-TimestampFromFile -File $nextFile
        $timeDifference = New-TimeSpan -Start $lastTimestamp -End $nextTimestamp
        if ($timeDifference.TotalSeconds -gt 0 -and $timeDifference.TotalSeconds -le $maxTimeBetweenShots) {
            $imageGroup.Add($nextFile); $lastTimestamp = $nextTimestamp; $j++
        } else { break }
    }
    $recipeGroups.Add($imageGroup)
    $i = $j
}

# --- Stage 2: Process Groups in Parallel using Start-ThreadJob ---
Write-Host "Found $($recipeGroups.Count) recipe groups. Starting parallel processing..."

$scriptBlock = {
    param($imageGroup, $apiKey, $maxRetries, $retryInitialDelayMs)
    function Convert-ImageToBase64 { param ([string]$ImagePath) try { return [System.Convert]::ToBase64String([System.IO.File]::ReadAllBytes($ImagePath)) } catch { return $null } }
    function Invoke-OpenAiApi {
        param([string]$Uri, [hashtable]$Headers, [string]$Body, [string]$ApiCallType, [int]$MaxRetries, [int]$RetryInitialDelayMs)
        $sanitizedUri = $Uri.Trim("[]"); $retries = 0; $delay = $RetryInitialDelayMs
        while ($retries -lt $MaxRetries) {
            $retries++; $response = $null
            try { $response = Invoke-WebRequest -Uri $sanitizedUri -Method Post -Headers $Headers -Body $Body -ContentType "application/json" -SkipHttpErrorCheck } catch { Start-Sleep -Milliseconds $delay; $delay *= 2; continue }
            if ($response.StatusCode -eq 200) { return $response.Content }
            if ($response.StatusCode -eq 429) { Start-Sleep -Milliseconds $delay; $delay *= 2; continue }
            return $null
        }
        return $null
    }
    function Get-OcrTextFromImage {
        param ([string]$base64Image, [string]$ApiKey, [int]$MaxRetries, [int]$RetryInitialDelayMs)
        $headers = @{ "Authorization" = "Bearer $ApiKey" }
        $body = @{ "model" = "gpt-4o"; "messages" = @(@{ "role" = "user"; "content" = @(@{ "type" = "text"; "text" = "Extract all the text from this image." }, @{ "type" = "image_url"; "image_url" = @{ "url" = "data:image/jpeg;base64,$base64Image" } }) }); "max_tokens" = 2000 } | ConvertTo-Json -Depth 10
        $responseJson = Invoke-OpenAiApi -Uri "https://api.openai.com/v1/chat/completions" -Headers $headers -Body $body -ApiCallType "OCR" -MaxRetries $MaxRetries -RetryInitialDelayMs $RetryInitialDelayMs
        if ($responseJson) { return ($responseJson | ConvertFrom-Json).choices[0].message.content }
        return $null
    }
    function Confirm-IsRecipe {
        param ([string]$OcrText, [string]$ApiKey, [int]$MaxRetries, [int]$RetryInitialDelayMs)
        $headers = @{ "Authorization" = "Bearer $ApiKey" }

        # --- First Pass Check ---
        $prompt1 = 'You are a text classification expert. Your task is to determine if the following text, extracted from a phone or computer screenshot, contains a food recipe. The text may be noisy. Your goal is to find the core content. A food recipe must have at least two of the following three elements: a clear title, a list of ingredients, or preparation steps. Respond with a single, raw JSON object with two keys: "is_recipe" (boolean) and "reason" (a brief explanation). --- Text to analyze: ' + $OcrText
        $body1 = @{ "model" = "gpt-4o"; "messages" = @(@{ "role" = "user"; "content" = $prompt1 }); "max_tokens" = 100; "response_format" = @{ "type" = "json_object" } } | ConvertTo-Json -Depth 10
        $responseJson1 = Invoke-OpenAiApi -Uri "https://api.openai.com/v1/chat/completions" -Headers $headers -Body $body1 -ApiCallType "Recipe Check 1" -MaxRetries $MaxRetries -RetryInitialDelayMs $RetryInitialDelayMs

        $initialResult = if ($responseJson1) { ($responseJson1 | ConvertFrom-Json).choices[0].message.content | ConvertFrom-Json } else { [PSCustomObject]@{ is_recipe = $false; reason = "API call failed during initial recipe check." } }
        if ($initialResult.is_recipe) {
            return $initialResult # It's a recipe, no need to double-check
        }

        # --- Second Pass (Double-Check) ---
        $prompt2 = 'A previous analysis suggested the following text might not be a food recipe. Please take a second, closer look. The text was extracted from a messy screenshot and may be poorly formatted. Re-evaluate the text for any evidence of a recipe, such as a title, a list of ingredients (lines starting with quantities or bullets), or cooking instructions (numbered steps or paragraphs describing a process). Look carefully. Sometimes a recipe is present even if the formatting is poor. Based on your second analysis, is there a food recipe anywhere in this text? Respond with a single, raw JSON object with two keys: "is_recipe" (boolean) and "reason" (a brief, one-sentence explanation for your final decision). --- Text to re-evaluate: ' + $OcrText
        $body2 = @{ "model" = "gpt-4o"; "messages" = @(@{ "role" = "user"; "content" = $prompt2 }); "max_tokens" = 100; "response_format" = @{ "type" = "json_object" } } | ConvertTo-Json -Depth 10
        $responseJson2 = Invoke-OpenAiApi -Uri "https://api.openai.com/v1/chat/completions" -Headers $headers -Body $body2 -ApiCallType "Recipe Check 2" -MaxRetries $MaxRetries -RetryInitialDelayMs $RetryInitialDelayMs

        if ($responseJson2) {
            return ($responseJson2 | ConvertFrom-Json).choices[0].message.content | ConvertFrom-Json
        }
        return [PSCustomObject]@{ is_recipe = $false; reason = "API call failed during second recipe check." }
    }
    function Get-StructuredRecipeData {
        param ([string]$OcrText, [string]$ApiKey, [int]$MaxRetries, [int]$RetryInitialDelayMs)
        $headers = @{ "Authorization" = "Bearer $ApiKey" }
        $csvHeaders = "'Title', 'Course', 'Cuisine', 'Main Ingredient', 'Description', 'Source', 'Url', 'Url Host', 'Prep Time', 'Cook Time', 'Total Time', 'Servings', 'Yield', 'Ingredients', 'Directions', 'Tags', 'Rating', 'Public Url', 'Photo Url', 'Private', 'Nutritional Score (generic)', 'Calories', 'Fat', 'Saturated Fat', 'Cholesterol', 'Sodium', 'Sugar', 'Carbohydrate', 'Fiber', 'Protein', 'Cost', 'Created At', 'Updated At'"
        $prompt = "You are an expert recipe data extractor. Convert the following text into a structured JSON object. Instructions: 1. Title: If a title exists, use that exact title. If not, generate one. Always append a food emoji to the end. 2. Main Ingredient: Identify the SINGLE most predominant ingredient (e.g., ""Chicken"", ""Beef""). This field MUST NOT contain commas. 3. Rating: The `Rating` field MUST always be an empty string. 4. Other Mandatory Fields: Provide a single value for `Course` and `Cuisine`, and a comma-separated list for `Tags`. 5. Formatting: For `Ingredients` and `Directions`, separate items with `\n`. 6. Dates: For `Created At` and `Updated At`, use the format 'yyyy-MM-dd HH:mm:ss'. The current UTC time is $(Get-Date -UFormat '%Y-%m-%d %H:%M:%S'). 7. Output: Your response MUST be a single, raw JSON object with keys for all of these fields: $($csvHeaders). --- Recipe Text: " + $OcrText
        $body = @{ "model" = "gpt-4.1-nano"; "messages" = @(@{ "role" = "user"; "content" = $prompt }); "max_tokens" = 4096; "response_format" = @{ "type" = "json_object" } } | ConvertTo-Json -Depth 10
        $responseJson = Invoke-OpenAiApi -Uri "https://api.openai.com/v1/chat/completions" -Headers $headers -Body $body -ApiCallType "Recipe Structuring" -MaxRetries $MaxRetries -RetryInitialDelayMs $RetryInitialDelayMs
        if ($responseJson) { return ($responseJson | ConvertFrom-Json).choices[0].message.content | ConvertFrom-Json -ErrorAction SilentlyContinue }
        return $null
    }
    function Clean-StringForCsv { param ([string]$InputString) if ([string]::IsNullOrWhiteSpace($InputString)) { return "" }; return $InputString.Trim() -replace '\s+', ' ' }

    # Main Job Logic
    $groupFileNamesForReport = $imageGroup | ForEach-Object { $_.Name } | Join-String -Separator ", "
    $combinedOcrText = [System.Text.StringBuilder]::new()
    foreach ($imageFileInGroup in $imageGroup) {
        $base64Image = Convert-ImageToBase64 -ImagePath $imageFileInGroup.FullName
        if (-not $base64Image) { continue }
        $ocrText = Get-OcrTextFromImage -base64Image $base64Image -ApiKey $apiKey -MaxRetries $maxRetries -RetryInitialDelayMs $retryInitialDelayMs
        if (-not $ocrText) { continue }
        [void]$combinedOcrText.AppendLine($ocrText)
    }
    if ($combinedOcrText.Length -eq 0) {
        return [PSCustomObject]@{ Status = 'Skipped'; Data = @{ GroupFiles = $groupFileNamesForReport; Reason = "Could not get any text from the images." } }
    }
    $ocrTextForNextSteps = $combinedOcrText.ToString()
    $isRecipeResult = Confirm-IsRecipe -OcrText $ocrTextForNextSteps -ApiKey $apiKey -MaxRetries $maxRetries -RetryInitialDelayMs $retryInitialDelayMs
    if (-not $isRecipeResult.is_recipe) {
        return [PSCustomObject]@{ Status = 'Skipped'; Data = @{ GroupFiles = $groupFileNamesForReport; Reason = "[Final Decision] " + $isRecipeResult.reason } }
    }
    $recipeDataObject = Get-StructuredRecipeData -OcrText $ocrTextForNextSteps -ApiKey $apiKey -MaxRetries $maxRetries -RetryInitialDelayMs $retryInitialDelayMs
    if (-not $recipeDataObject) {
        return [PSCustomObject]@{ Status = 'Skipped'; Data = @{ GroupFiles = $groupFileNamesForReport; Reason = "Failed to structure recipe data from the combined text." } }
    }
    $recipeDataObject.Title = Clean-StringForCsv -InputString $recipeDataObject.Title
    return [PSCustomObject]@{ Status = 'Success'; Data = $recipeDataObject }
}

$jobs = @()
foreach ($group in $recipeGroups) {
    while (@(Get-Job -State Running).Count -ge $ThrottleLimit) {
        Start-Sleep -Seconds 1
    }
    $job = Start-ThreadJob -ScriptBlock $scriptBlock -ArgumentList @($group, $apiKey, $maxRetries, $retryInitialDelayMs)
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

$results = $jobs | Receive-Job
$jobs | Remove-Job

# --- Stage 3: Finalize and Export CSV ---
$processedRecipes = $results | Where-Object { $_.Status -eq 'Success' } | Select-Object -ExpandProperty Data
$skippedGroups = $results | Where-Object { $_.Status -eq 'Skipped' } | Select-Object -ExpandProperty Data

if ($processedRecipes.Count -gt 0) {
    try {
        $processedRecipes | Export-Csv -Path $csvFilePath -NoTypeInformation -Encoding utf8NoBOM
        Write-Host "`nSuccessfully created CSV export with $($processedRecipes.Count) recipes: $csvFilePath" -ForegroundColor Green
        Write-Host "The output file is formatted for import into the Plan to Eat recipe manager." -ForegroundColor Cyan
    } catch {
        Write-Error "Failed to create CSV file: $_"
    }
} else {
    Write-Warning "No recipes were successfully processed to create a CSV file."
}

# --- Final, Comprehensive Report ---
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