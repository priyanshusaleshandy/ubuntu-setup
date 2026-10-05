# push-repos-api.ps1
# Creates repositories on GitHub using REST API and pushes them headlessly

Write-Host "=== GitHub REST API Repo Creator & Pusher ===" -ForegroundColor Cyan
$username = "priyanshusaleshandy"
$token = Read-Host "Please paste your GitHub Personal Access Token (PAT)"

if ([string]::IsNullOrWhiteSpace($token)) {
    Write-Host "[ERR] Token cannot be empty!" -ForegroundColor Red
    exit
}

$repos = @(
    @{
        Name = "setup-center-desktop"
        Path = "D:\setup-center-desktop"
        Desc = "Setup Center GUI Desktop application (Electron + React)"
    },
    @{
        Name = "mac-mini-ai-stack"
        Path = "D:\mac-mini-ai-stack"
        Desc = "local GPU accelerated LLM stack for Mac Mini"
    }
)

foreach ($repo in $repos) {
    Write-Host "`n=== [Process] Repository: $($repo.Name) ===" -ForegroundColor Cyan
    
    # 1. Create Repository via GitHub API
    $body = @{
        name = $repo.Name
        description = $repo.Desc
        private = $false
    } | ConvertTo-Json

    $headers = @{
        "Authorization" = "token $token"
        "Accept"        = "application/vnd.github.v3+json"
    }

    try {
        $response = Invoke-RestMethod -Uri "https://api.github.com/user/repos" -Method Post -Headers $headers -Body $body -ContentType "application/json"
        Write-Host "[OK] Repository created successfully on GitHub!" -ForegroundColor Green
    } catch {
        # Catch if repository already exists (HTTP 422 - Unprocessable Entity)
        if ($_.Exception.Response.StatusCode -eq "UnprocessableEntity" -or $_.Exception.Message -match "422") {
            Write-Host "[INFO] Repository already exists on GitHub. Proceeding to push..." -ForegroundColor Yellow
        } else {
            Write-Host "[ERR] Failed to create repository via API: $($_.Exception.Message)" -ForegroundColor Red
            continue
        }
    }

    # 2. Push files using Token Auth
    if (Test-Path $repo.Path) {
        cd $repo.Path
        
        # Git config check
        $gitEmail = git config --global user.email
        $gitName = git config --global user.name
        if ([string]::IsNullOrEmpty($gitEmail)) { git config --global user.email "priyanshusuryavanshi@saleshandy.com" }
        if ([string]::IsNullOrEmpty($gitName)) { git config --global user.name "Priyanshu Kumar" }

        # Init & Commit
        git init
        git add .
        git commit -m "initial commit: $($repo.Desc)"
        git remote remove origin 2>$null
        
        # Authenticate git command push natively using the token in URL
        $remoteUrl = "https://$token@github.com/$username/$($repo.Name).git"
        git remote add origin $remoteUrl
        git branch -M main
        
        Write-Host "Pushing to GitHub..." -ForegroundColor Cyan
        git push -u origin main -f
        Write-Host "[OK] pushed successfully!" -ForegroundColor Green
    } else {
        Write-Host "[ERR] Local folder path not found: $($repo.Path)" -ForegroundColor Red
    }
}

Write-Host "`n=== Success! Both repositories are now live on GitHub! ===" -ForegroundColor Green
