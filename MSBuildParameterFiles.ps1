﻿$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

#Custom Classes
if (-not ([System.Management.Automation.PSTypeName]'MsBuild.SetParameter').Type)
{
Add-Type -Language CSharp @"
	namespace MSBuild
	{
		public class SetParameter
		{
	        public string Name { get; set; }
	        public string EnvKey { get; set; }
		}
	}
"@;
}
function Add-Parameter
{	
	<#
	.DESCRIPTION
		Adds a parameter xml node element to the paramaters document root of a parameters.xml file
	.PARAMETER xmlDocument
		The xml document to add the parameter to. This should already contain a root element called parameters
	.PARAMETER name
		The name of the parameter being added. This is the name that will be used in the setparameters.xml file as well
	.PARAMETER value
		The default value to be used if a setParameter does not exist when the application is deployed
	.PARAMETER kind
		The type of file being processed. Either XmlFile or TextFile. See MS docs for more details
	.PARAMETER scope
		The scope of the parameter. A regex used for locating the files to apply the parameter to. See MS docs for more details
	.PARAMETER $match
		A match string used to find the parameter in the given scope. For XML files this will be an xdata path, for Text files this will be a relace string
	#>
	Param(
		[XML]		[Parameter(Mandatory=$true)]	$xmlDocument, 
		[String]	[Parameter(Mandatory=$true)]	$name, 
		[String]	[Parameter(Mandatory=$true)]	$value, 
		[String]	[Parameter(Mandatory=$true)]	$kind, 
		[String]	[Parameter(Mandatory=$true)]	$scope, 
		[String]	[Parameter(Mandatory=$true)]	$match
	)
	Write-Host "    Adding: $name with scope: $scope"
    # Create a new parameter node for the attribute
    [System.XML.XMLElement]$parameterNode = $xmlDocument.CreateElement("parameter")
    $parameterNode.SetAttribute("name", $name)
    $parameterNode.SetAttribute("defaultValue",$value)

    # Create a new parameterEntry node for the attribute
    [System.XML.XMLElement]$parameterEntryNode = $xmlDocument.CreateElement("parameterEntry")
    $parameterEntryNode.SetAttribute("kind", $kind)
    $parameterEntryNode.SetAttribute("scope", [regex]::escape($scope))
    $parameterEntryNode.SetAttribute("match", $match)

    # Add the parameterEntry node to the parameter node
    $result = $parameterNode.AppendChild($parameterEntryNode)

    # Add the parameter node to the parameters node
    $result = $xmlDocument.DocumentElement.AppendChild($parameterNode)
}

function Add-SetParameter
{ 
	#TODO: check if value exists and if it does replace it
	
	<#
	.DESCRIPTION
		Adds a setParameter xml node element to the paramaters document root of a parameters.xml file
	.PARAMETER xmlDocument
		The xml document to add the parameter to. This should already contain a root element called parameters
	.PARAMETER name
		The name of the parameter being added. This name should match a parameter entry in the MSBuild parameters.xml file
	.PARAMETER value
		The value to pass when the package is deployed
	#>
	Param(
		[XML]		[Parameter(Mandatory = $true)]	$xmlDocument, 
		[String]	[Parameter(Mandatory = $true)]	$name, 
		[String]	[Parameter(Mandatory = $true)]  [AllowEmptyString()] $value
	)
    Write-Host "    Adding: $name"
	$existingNode = $xmlDocument.SelectSingleNode("/parameters/setParameter[@name='$name']")
	if(!$existingNode)
	{
	    [System.XML.XMLElement]$child = $xmlDocument.CreateElement("setParameter")
	    $child.SetAttribute("name", $name)
	    $child.SetAttribute("value",$value)
	    $result = $xmlDocument.DocumentElement.AppendChild($child)
	}
	else
	{
		$existingNode.Value = $value;
	}
}

function Update-ParametersFile
{
	<#
	.DESCRIPTION
		Updates an existing parameters.xml file based on the passed in configuration files.
	.PARAMETER $configFiles
		An array of configFiles to process
		The config files can be of two types. XML or Text
		XML Config files should contain only a root element with attributes for each configuration value
		Example XML Config file:
		<logging location="c:\logs">
		Text Config files should contain replacement text in the form /* SOMEVALUE */
		Example Text Config file:
		My file needs this /* VALUE */ updated
	.PARAMETER $overrideScope
		A scope used to override the location of the parameter. Given in full path from the project root.
		Provides a scope to use for all parameters. This is useful in the case of configuration files
		that may be minimized into a single file during deployment.
		
	.PARAMETER projectDir
		The root directory of the project being processed. This is the location where the parameters.xml will be saved and the root of the relative path used for parameter scopes
	#>
	Param(
		[System.IO.FileSystemInfo[]]	[Parameter(Mandatory = $true)]	$configFiles, 
		[String]						[Parameter(Mandatory = $true)]	$projectDir,
		[String]														$overrideScope
	)
	$origonalLocation = Get-Location
	Set-Location $projectDir
	#########
	## Create the Parameters file
	#########
	Write-Host "Creating Parameters.xml"
	$parametersPath = "$projectDir\parameters.xml"
	# Create the base XML paramaters structure
	[System.XML.XMLDocument]$parameterFile = New-Object System.XML.XMLDocument
	$parameterFile.Load($parametersPath)

	# Cycle each config file
	Foreach ($configFile in $configFiles)
	{
	    Write-Host "Processing "$configFile.Name
	    
	    # Cycle each attribute in the value node	
		$parameters = @{}
		# Determine correct file scope
		$scope =  @{$true=($configFile.FullName | Resolve-Path -Relative) -replace "^\.\\", ""; $false=$overrideScope}[[string]::IsNullOrEmpty($overrideScope)]

		if(".xml",".config" -contains $configFile.Extension.ToLower())
		{
			# Read the file
			[xml]$xmlFileContent = Get-Content $configFile.FullName
			# Determine replacable variables
            
			if(-not $xmlFileContent.DocumentElement.HasAttributes)#hack for amazonS3.config in Essentials that I need to get them to fix
			{
				$attributes = $xmlFileContent.DocumentElement.FirstChild.FirstChild.Attributes;
				$parameters = @($attributes | 
				Foreach { 
					@{
						Name = "$($configFile.BaseName).$($_.Name)";
						Value = $_.Value;
						Match = "//$($configFile.BaseName)//namedconfigs//add/@$($_.Name)";
						Scope = $scope;
						Kind = "XmlFile"
					}
				})
			}
			else
			{
				$attributes = $xmlFileContent.DocumentElement.Attributes;
				$parameters = @($attributes | 
				Foreach { 
					@{
						Name = "$($configFile.BaseName).$($_.Name)";
						Value = $_.Value;
						Match = "//$($configFile.BaseName)/@$($_.Name)";
						Scope = $scope;
						Kind = "XmlFile"
					}
				})
			}
		}
		else
		{
			# Read the file
			$fileContent = Get-Content -Path $configFile | Out-String
			# Determine replacable variables
			$regex = new-object Text.RegularExpressions.Regex '(?<=@echo )[A-Z_]*(?= )', ('singleline')
			$parameters = @($regex.Matches($fileContent) | 
			Foreach { 
				@{
					Name = $_.Value;
					Value = "/* @echo $($_.Value) */";
					Match = "/\* @echo $($_.Value) \*/";
					Scope = $scope;
					Kind = "TextFile"
				}
			})
		}
	    Foreach($parameter in $parameters)
	    {
	        Add-Parameter $parameterFile $parameter.Name $parameter.Value $parameter.Kind $parameter.Scope $parameter.Match  
	    }    
	}
	$parameterFile.Save($parametersPath)
	Set-Location $origonalLocation
}

function Create-SetParametersFile
{
	<#
	.DESCRIPTION
		Creates a setparameters.xml file for each server in the serverArray. The setParameters file will be filled based on available environment variables
	.PARAMETER $serverArray
		An array of strings Example:("test","staging")
		Also supports sub deployments For example a deployment named production_eu would consist of all of the values from production plus all values form production_eu
		If any values are duplicated between the two, the items from the sub deployment will superceed.
	.PARAMETER $envFilter
		A begins with filter to apply to the available environment variables Example: "config.ui"
	.PARAMETER $outputDir
		The location to save the setParameters.xml file in. File will be saved as set$($server)Parameters.xml
	.PARAMETER $webPath
		The IIS application name to use for this set of parameters
	.PARAMETER $additionalParams
		If provided, an array of additional set parameters to create.
		Each object should be in tehe form @(Name="",EnvKey=""} where Name matches to a parameter entry in the parameters.xml file and EnvKey matches to an environment variable with $envFilter		
	#>
	Param(
		[String[]]					[Parameter(Mandatory=$true)]	$serverArray, 
		[String]					[Parameter(Mandatory=$true)]	$envFilter,
		[String]					[Parameter(Mandatory=$true)]	$webPath,
		[String]					[Parameter(Mandatory=$true)]	$outputDir,
		[MSBuild.SetParameter[]]									$additionalParams
	)
	#########
	## Create the setParameter files
	#########

	Foreach($server in $serverArray)
	{
	    Write-Host "Process Server: $server"
		
		$serverSplit =$server.split("_")
		if($serverSplit.Count -gt 1)
		{
			$primary = $serverSplit[0]
			$secondary = $serverSplit[1]
			$server = "$primary$secondary"
		}
		else
		{
			$primary = $server
		}
	    [System.XML.XMLDocument]$setParametersFile = New-Object System.XML.XMLDocument
	    [System.XML.XMLElement]$parametersNode = $setParametersFile.CreateElement("parameters")
		$result = $setParametersFile.AppendChild($parametersNode)
		
	    Get-ChildItem Env: | 
			where {  $_.Name.StartsWith("$envFilter.$primary.")} | 
			% {
				$name = $_.Name -replace "$envFilter.$primary.", ""
				$value = $_.Value
				Add-SetParameter $setParametersFile $name $value
			}
			
		Write-Host "Proccessing additional parameters"
		if($additionalParams -and $additionalParams.Length -ne 0)
		{
			Foreach($additionalParam in $additionalParams)
			{
				$param = Get-ChildItem Env: | 
					where {  $_.Name -eq "$($envFilter).$($primary).$($additionalParam.EnvKey)"}
				Add-SetParameter $setParametersFile $additionalParam.Name $param.Value
			}			
		}	  
		
		if($secondary)
		{
			Get-ChildItem Env: | 
				where {  $_.Name.StartsWith("$envFilter.$server")} | 
				% {
					$name = $_.Name -replace "$envFilter.$server.", ""
					$value = $_.Value
					Add-SetParameter $setParametersFile $name $value
				}
			Write-Host "Proccessing additional parameters"
			if($additionalParams -and $additionalParams.Length -ne 0)
			{
				Foreach($additionalParam in $additionalParams)
				{
					$param = Get-ChildItem Env: | 
						where {  $_.Name -eq "$($envFilter).$($server).$($additionalParam.EnvKey)"}
					Add-SetParameter $setParametersFile $additionalParam.Name $param.Value
				}			
			}	  
		}

		if($webPath)
		{
	    	Write-Host "Add the web site path"
			Add-SetParameter $setParametersFile "IIS Web Application Name" $webPath
		}
		
		  
		
	    $setFile = "$($outputDir)\set$($server)Parameters.xml"
	    Write-Host "Saving the SetParameters file: $setFile"
	    $setParametersFile.Save($setFile)
	}
}
### Sample code for generating MyCloud API setparameters.xml
#The set env stuff isn't working, create via console for now...
<#
${Env:config.api.production.BLARG}="blarg"
${Env:config.api.production.mongo.connection}="production value"
${Env:config.api.productioneu.mongo.connection}="production eu value"

$serverArray = "demo","sprint","staging","test","production","production_eu"
#Secondary servers will have an underscore in the server array, but that will be removed for all other purposes.
$envFilter = "config.api"
$webPath = "Default Web Site/act"
$outputDir = "c:\temp"
[MSBuild.SetParameter[]]$additionalParams =  @(
		New-Object MSBuild.SetParameter -Property @{Name="MongoDB-Web.config Connection String";EnvKey="mongo.connection"}
	)
Create-SetParametersFile $serverArray $envFilter $webPath $outputDir $additionalParams
#>


### Sample code for generating MyCloud API parameters.xml
<#
$configFiles = Get-ChildItem "c:\git\act\act\Configuration\*.config"
$projectDor = "c:\git\act\act"
Update-ParametersFile $configFiles $projectDor
#>

### Sample code for generating MyCloud UI parameters.xml
<#
Set-Location 'c:\git\act'
# Read the preprocess file and grab the files that need to be parameterized
$preprocess = Get-Content "c:\git\act\grunt_tasks\preprocess.js" | Out-String
$regex = new-object Text.RegularExpressions.Regex ".*module.exports = {", ('singleline','multiline')
$preprocess = $regex.Replace($preprocess, "{")
$preprocess = $preprocess -replace ";", ""
$json = ConvertFrom-Json $preprocess
$configPairs = ($json.dev.files | Get-Member * -MemberType NoteProperty ) | Foreach { @{Destination = $_.Name.ToString(); Source=$json.dev.files.$($_.Name)}}

# Copy the preprocess to the final
$configPairs | Foreach {Copy-Item -Path $_.Source -Destination $_.Destination}

# Setup variables for the helper call
$configFiles = ($json.dev.files | Get-Member * -MemberType NoteProperty) | Foreach {Get-Item $_.Name}
$projectDir = "c:\git\act\APICloudFormation\act.web.deploy"

Update-ParametersFile $configFiles $projectDir
#>
