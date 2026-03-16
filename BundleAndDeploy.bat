@echo off
setlocal

set "targetFile=%localappdata%\lua\Cheater_Detection.lua"
set "hadBefore=0"
if exist "%targetFile%" (
	set "hadBefore=1"
	for %%I in ("%targetFile%") do (
		set "beforeSize=%%~zI"
		set "beforeTime=%%~tI"
	)
)

node bundle.js
if errorlevel 1 (
	echo [BundleAndDeploy] NOT DEPLOYED: bundle.js returned non-zero exit code.
	exit /b 1
)

if not exist "%targetFile%" (
	echo [BundleAndDeploy] NOT DEPLOYED: target file missing: "%targetFile%"
	exit /b 1
)

for %%I in ("%targetFile%") do (
	set "afterSize=%%~zI"
	set "afterTime=%%~tI"
)

if "%hadBefore%"=="0" (
	echo [BundleAndDeploy] DEPLOYED: created "%targetFile%" size=%afterSize% modified=%afterTime%
) else (
	if "%beforeSize%"=="%afterSize%" if "%beforeTime%"=="%afterTime%" (
		echo [BundleAndDeploy] DEPLOYED: target exists and bundler succeeded, content unchanged size=%afterSize% modified=%afterTime%
	) else (
		echo [BundleAndDeploy] DEPLOYED: updated "%targetFile%" size=%afterSize% modified=%afterTime%
	)
)

exit /b 0