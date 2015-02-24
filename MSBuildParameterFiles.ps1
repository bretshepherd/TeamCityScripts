$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
function AddParameter([XML]$xmlDocument, $name, $value, $kind, $scope, $match)
{
	Write-Host "    Adding: $name"
    # Create a new parameter node for the attribute
    [System.XML.XMLElement]$parameter=$xmlDocument.CreateElement("parameter")
    $parameter.SetAttribute("name", $name)
    $parameter.SetAttribute("defaultValue",$value)

    # Create a new parameterEntry node for the attribute
    [System.XML.XMLElement]$parameterEntry= $xmlDocument.CreateElement("parameterEntry")
    $parameterEntry.SetAttribute("kind", $kind)
    $parameterEntry.SetAttribute("scope", $scope)
    $parameterEntry.SetAttribute("match", $match)

    # Add the parameterEntry node to the parameter node
    $result = $parameter.AppendChild($parameterEntry)

    # Add the parameter node to the parameters node
    $result = $xmlDocument.DocumentElement.AppendChild($parameter)
}

function AddSetParameter([XML]$xmlDocument, $name, $value)
{
    Write-Host "    Adding: $setName"
    [System.XML.XMLElement]$child = $xmlDocument.CreateElement("setParameter")
    $child.SetAttribute("name", $name)
    $child.SetAttribute("value",$value)
    $result = $xmlDocument.DocumentElement.AppendChild($child)
}

function CreateMSBuildParametersFile($configFiles, $parametersPath)
{

	#########
	## Create the Parameters file
	#########
	Write-Host "Creating Parameters.xml"

	# Create the base XML paramaters structure
	[System.XML.XMLDocument]$parameterFile=New-Object System.XML.XMLDocument
	$parameterFile.Load($parametersPath)
	[System.XML.XMLElement]$parameters=$parameterFile.DocumentElement

	# Cycle each config file
	Foreach ($configFile in $configFiles)
	{
	    Write-Host "Processing "$configFile.Name
	    
	    # Cycle each attribute in the value node	
		$kind = ""
		$matches = @{}
		if(".xml",".config" -contains $configFile.Extension.ToLower())
		{
			$kind = "XmlFile"
			# Read the file
			[xml]$fileContent = Get-Content $configFile.FullName
			# Determine replacable variables
			$matches = @($fileContent.DocumentElement.Attributes | Foreach { @{Name = $_.Name;Value =  "//$($configFile.BaseName)/@$($match.Name)" }})
		}
		else
		{
			$kind = "TextFile"
			# Read the file
	    	$fileContent = Get-Content -Path $configFile | Out-String
			# Determine replacable variables
			$regex = new-object Text.RegularExpressions.Regex '(?<=@echo )[A-Z_]*(?= )', ('singleline')
			$matches = @($regex.Matches($fileContent) | Foreach { @{Name = $_.Value;Value = "/* @echo $($_.Value) */" }})
		}
	    Foreach($match in $matches)
	    {
	        $name = $configFile.BaseName + "." +$match.Name
			$value = $match.Value
			$scope = "Configuration\\"+$configFile.Name
			$match = $match.Value
			
			AddParameter $parameterFile $name $value "XmlFile" $scope $match  
	    }    
	}
	$parameterFile.Save($parametersPath)
}