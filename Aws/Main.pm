use MooseX::Declare;

=head2

	PACKAGE		Virtual::Aws::Main
	
    VERSION:        0.01

    PURPOSE
  
        1. UTILITY FUNCTIONS TO ACCESS A MYSQL DATABASE

=cut 

use strict;
use warnings;
use Carp;
use File::Path qw(make_path);


class Virtual::Aws::Main with Util::Logger {

#### EXTERNAL MODULES
use JSON;

#### INTERNAL MODULES
use Conf::Yaml;
use Util::Ssh;


# Ints
has 'sleep'		=>  ( isa => 'Int', is => 'rw', default => 4 );  
has 'log'		=>  ( isa => 'Int', is => 'rw', default => 2 );  
has 'printlog'	=>  ( isa => 'Int', is => 'rw', default => 2 );

# Strings

# Objects
has 'conf'			=> ( isa => 'Conf::Yaml', is => 'rw', required	=>	0 );
has 'jsonparser'	=> ( isa => 'JSON', is => 'rw', lazy	=>	1, builder	=>	"setJsonParser"	);
has 'ssh'			=> ( isa => 'Util::Ssh', is => 'rw', lazy	=>	1, builder	=>	"setSsh"	);

####////}}}

method BUILD ($args) {
	$self->initialise($args);
}

method initialise ($args) {
	$self->logNote("");
}

method nodeExists ( $stageobject ) {
  # $self->logDebug( "stageobject", $stageobject );
  my $profilehash = $stageobject->{ profilehash };
  my $credentialsfile = $self->getProfileValue( "virtual:credentialsfile", $profilehash );
  my $configfile = $self->getProfileValue( "virtual:configfile", $profilehash );
  $self->logDebug( "credentialsfile", $credentialsfile );
  $self->logDebug( "configfile", $configfile );

  my $ipaddress = undef;
  my $instanceid = undef;
  my $tries = 5;
  my $delay = 2;
  my $counter = 0;

  my $tag = $self->getNameTag( $stageobject );
  while ( $counter < $tries and not defined $ipaddress ) {
    my $command = "AWS_CONFIG_FILE=$configfile \\
&& AWS_CREDENTIALS_FILE=$credentialsfile \\
&& aws ec2 describe-instances --filters $tag";
    my $output = `$command`;
    # $self->logDebug("output", $output);
    ($instanceid) = $output =~ /"InstanceId": "([^"]+)"/;
    ($ipaddress) = $output =~ /"PublicIpAddress": "([^"]+)"/;
    $self->logDebug("ipaddress", $ipaddress);
    sleep(2);
    $counter++;
  }

  my $instancename = $self->getInstanceName( $stageobject );

  return ( $instancename, $instanceid, $ipaddress );
}


#### LATER: REMOVE 
# method getInstance ( $stageobject ) {
#   $self->logDebug( "stageobject", $stageobject );
#   $self->logDebug( "ipaddress", $ipaddress );

#   my $query = "SELECT * FROM instance WHERE ipaddress='$ipaddress'";
#   my $instance = $self->table()->db()->queryhash($query);
#   $self->logDebug( "instance", $instance );
# }

# method addInstance ( $stageobject, $ipaddress ) {
#   $self->logDebug( "stageobject", $stageobject );
#   $self->logDebug( "ipaddress", $ipaddress );

#   my $query = "SELECT * FROM instance WHERE ipaddress='$ipaddress'";
#   my $instance = $self->table()->db()->queryhash($query);
#   $self->logDebug( "instance", $instance );
# }

# method deleteInstance ( $stageobject, $ipaddress ) {
#   $self->logDebug( "stageobject", $stageobject );
#   $self->logDebug( "ipaddress", $ipaddress );

#   my $query = "SELECT * FROM instance WHERE ipaddress='$ipaddress'";
#   my $instance = $self->table()->db()->queryhash($query);
#   $self->logDebug( "instance", $instance );
# }

method getNameTag ( $stageobject ) {
  my $instancename     =    $self->getInstanceName( $stageobject );
  $self->logDebug( "instancename", $instancename );

  return "Name=tag-value,Values=$instancename";
}

method getInstanceName ( $stageobject ) {
  my $username         =    $stageobject->username();
  my $projectname      =    $stageobject->projectname();
  my $workflowname     =    $stageobject->workflowname();
  my $stagenumber      =    $stageobject->appnumber();
  my $stagename        =    $stageobject->appname();
  my $profilehash      =    $stageobject->{ profilehash };
  my $imagename        =    $self->getProfileValue( "virtual:image:name", $profilehash );

  return "$imagename-$username-$projectname-$workflowname";
}

method launchNode ( $stageobject ) {
  # $self->logDebug( "stageobject", $stageobject );
  my $username         =    $stageobject->username();
  my $projectname      =    $stageobject->projectname();
  my $workflowname     =    $stageobject->workflowname();
  my $stagenumber      =    $stageobject->appnumber();
  my $stagename        =    $stageobject->appname();
  my $profilehash      =    $stageobject->{ profilehash };
  $self->logDebug( "profilehash", $profilehash );

  my $imageid = $self->getProfileValue( "virtual:image:id", $profilehash );
  my $instancetype = $self->getProfileValue( "virtual:instance:type", $profilehash );
  my $instancename = $self->getInstanceName( $stageobject );
  my $disksize = $self->getProfileValue( "virtual:disk:size", $profilehash );

  $self->logDebug( "imageid", $imageid );
  $self->logDebug( "instancetype", $instancetype );
  $self->logDebug( "instancename", $instancename );
  $self->logDebug( "disksize", $disksize );

  #### CREDENTIALS AND CONFIG FILE
  my $credentialsfile        =   $self->getProfileValue( "virtual:credentialsfile", $profilehash );
  $self->logDebug("credentialsfile", $credentialsfile);
  my $configfile        =   $self->getProfileValue( "virtual:configfile", $profilehash );
  $self->logDebug("configfile", $configfile);

  my $userdatafile    =   $self->getProfileValue( "virtual:userdata", $profilehash );
  $self->logDebug("userdatafile", $userdatafile);

  #### VOLUME MAPPING FILE
  my $workflowdir     = $self->getWorkflowDir( $stageobject );
  my $mappingfile     = "$workflowdir/$stagenumber-$stagename-block-mappings.json";
  $self->logDebug("mappingfile", $mappingfile);
  $self->printMappingFile( $mappingfile, $disksize );
 
  my $keypair  = $self->getProfileValue( "virtual:keypair", $profilehash );
  my $region  = $self->getProfileValue( "virtual:region", $profilehash );

  #### TO DO: FIX MAPPING - CAUSES FAILURE OF SSH TO INSTANCE 
  #### --block-device-mappings=file://$mappingfile \\
    
  my $aws = $self->getAws();

  my $command  =  "AWS_CONFIG_FILE=$configfile \\
&& AWS_CREDENTIALS_FILE=$credentialsfile \\
&& $aws ec2 run-instances \\
--key-name $keypair \\
--image-id $imageid \\
--instance-type $instancetype \\
";
  $self->logDebug( "command", $command );

  if ( defined $userdatafile and $userdatafile ne "" ) {
    $command .= "--user-data file://$userdatafile \\";
  }
  $command .= "\n";

  $self->logDebug( "command", $command );

#### DEBUG
#### DEBUG
#### DEBUG

  my ( $out, $err )   =  $self->runCommand( $command );
  $self->logDebug("out", $out);
  $self->logDebug("err", $err);

  my $instanceid  =  $self->parseLaunchOutput( $out );
  # my $instanceid = "i-024b48eb744330732";
  # $self->logDebug("instanceid", $instanceid);
  

  my $ipaddress = $self->ipFromInstanceId($instanceid, $credentialsfile, $configfile); 
  $self->logDebug("ipaddress", $ipaddress);
  
  $self->setInstanceName( $instanceid, $instancename );

# $self->logDebug( "DEBUG EXIT" );
# exit;
    
  return ( $instancename, $instanceid, $ipaddress );
}

method ipFromInstanceId ( $instanceid, $credentialsfile,$configfile ) {
  $self->logDebug( "instanceid", $instanceid );

  my $ipaddress = undef;
  my $tries = 10;
  my $delay = 2;
  my $counter = 0;

  #### SET AUTHENTICATION ENVARS
  $ENV{'AWS_CONFIG_FILE'} = $configfile;
  $ENV{'AWS_CREDENTIALS_FILE'} = $credentialsfile;

  my $aws = $self->getAws();
  while ( $counter < $tries and not defined $ipaddress ) {
    my $command = "AWS_CONFIG_FILE=$configfile \\
&& AWS_CREDENTIALS_FILE=$credentialsfile \\
$aws ec2 describe-instances \\
--instance-ids $instanceid | grep PublicIpAddress";
    $self->logDebug( "command", $command );
    my $output = `$command`;
    $self->logDebug("output", $output);
    ($ipaddress) = $output =~ /"PublicIpAddress": "([^"]+)"/;
    $self->logDebug("ipaddress", $ipaddress);
    sleep( $delay );
  }

  return $ipaddress;
}

method getProfileValue ( $keystring, $profile ) {
  $self->logDebug( "keystring", $keystring );
  my @keys = split ":", $keystring;
  my $hash = $profile;
  foreach my $key ( @keys ) {
    $hash  = $hash->{$key};
    return undef if not defined $hash;
    $self->logDebug("hash", $hash);
  }

  return $hash;
}

method getAws {
    my $aws = "/usr/local/bin/aws";
    $aws = "/usr/bin/aws" if not -f $aws;
    $self->logDebug("aws", $aws);

    return $aws;
}

method setInstanceName ( $instanceid, $instancename ) {
  $self->logDebug("instanceid", $instanceid);
  $self->logDebug( "instancename", $instancename );
  
  my $aws = $self->getAws();
  my $command = qq{$aws ec2 create-tags \\
 --resources $instanceid \\
--tags Key=Name,Value=$instancename};
  $self->logDebug( "command", $command );

  my ($out, $err)   = $self->runCommand($command);
  $self->logDebug("out", $out);
  $self->logDebug("err", $err);

  return ($out, $err);
}

method printUserDataFile ( $templatefile, $workflowobject ) {
  $self->logDebug( "templatefile", $templatefile );
	$self->logDebug( "workflowobject", $workflowobject );

  my $userdatafile    =   $self->getUserDataFile( $workflowobject );
  $self->logDebug( "userdatafile", $userdatafile );
  
	#### GET TEMPLATE
	my $template		=	$self->getFileContents( $templatefile );
  $template = $self->insertConfigValues( $template );
	$template = $self->insertWorkflowValues( $template );
  $self->logDebug("templatefile", $templatefile);
  $self->logDebug("template", $template);

	# PRINT TEMPLATE
	$self->printToFile( $userdatafile, $template );

  return $userdatafile;
}

method getInstallDir ($packagename) {
  $self->logDebug("packagename", $packagename);

  my $packages = $self->conf()->getKey( "packages:$packagename" );
  $self->logDebug("packages", $packages);
  my $version = undef;
  foreach my $key ( %$packages ) {
    $version  = $key;
    last;
  }

  my $installdir  = $packages->{$version}->{INSTALLDIR};
  $self->logDebug("installdir", $installdir);
  
  return $installdir;
}

method getUserDataFile ( $workflowobject ) {
  $self->logDebug("workflowobject", $workflowobject);

	my $username		    =	$workflowobject->{ username };
  my $coredir         = $self->conf()->getKey( "core:DIR" );
	my $project			    =	$workflowobject->{ projectname };
	my $workflow		    =	$workflowobject->{ workflowname };
  my $userdir         = $self->conf()->getKey( "core:USERDIR" );
  my $userdatafile    = "$userdir/$username/$coredir/$project/$workflow/userdata";

  return $userdatafile;
}

method getTemplateFile ( $stageobject ) {
	# $self->logDebug( "stageobject", $stageobject );
  
  my $templatefile = undef;

  #### GET PROFILE virtual.userdata IF AVAILABLE  
  my $profilehash = $stageobject->{ profilehash };
  $self->logDebug( "profilehash", $profilehash );
  if ( defined $profilehash and defined $self->getProfileValue( "virtual:userdata", $profilehash ) ) {
    $templatefile = $self->getProfileValue( "virtual:userdata", $profilehash );
  }  
  #### OTHERWISE, GET userdata.sh FROM PACKAGE INSTALLDIR IF AVAILABLE
  elsif ( $stageobject->{ package } ) {
    my $package     = $stageobject->{package};
    my $version     = $stageobject->{version};
    $self->logDebug("package", $package);
    $self->logDebug("version", $version);
    
    #### SET CANONICAL LOCATION IN PACKAGE STR
    my $installdir    = $self->getInstallDir( $package );
    $self->logDebug("installdir", $installdir);
    $templatefile = "$installdir/data/sh/userdata.sh";    
  }
  $self->logDebug( "templatefile", $templatefile );

  return $templatefile;
}

method insertWorkflowValues( $template, $workflowobject ) {
  foreach my $key ( keys %$workflowobject ) {
    my $templatekey = uc($key);
    my $value = $workflowobject->{ $key };
    #$self->logDebug("substituting key $key value '$value' into template");
    $template =~ s/<$templatekey>/$value/msg;
  }

  return $template;
}

method insertConfigValues ($template) {
  $self->logDebug("template", $template);
    
  while ( $template =~ m/%([\S]+?)%/g ) {
    my $match = $1;
    my ($key, $subkey) = $match =~ /^(.+?):(.+)$/;
		my $value = $self->conf()->getKey($key, $subkey);
    
    $template =~ s/%$match%/$value/;
	}
  $self->logDebug("FINAL template", $template);
    
  return $template;
}

method printAuthFile {
	#### GET AUTH FILE
	my $authfile		=	$self->getAuthFile();
    $self->logDebug("authfile", $authfile);
    
    if ( -f $authfile and not -z $authfile ) {
        $self->logDebug("authfile found. Returning");
        return $authfile;
    }
    
	#### SET TEMPLATE FkILE	
	my $accesskeyid		=	$self->conf()->getKey( "core:AWSACCESSKEYID" );
	my $secretaccesskey =	$self->conf()->getKey( "core:AWSSECRETACCESSKEY" );

    my $contents = qq{[default]
aws_access_key_id=$accesskeyid
aws_secret_access_key=$secretaccesskey
};
	
	$self->printToFile($authfile, $contents);

	return $authfile;
}

method printMappingFile ( $mappingfile, $disksize ) {
  $self->logDebug( "mappingfile", $mappingfile );
  $self->logDebug( "disksize", $disksize );
  
  my ($parentdir) = $mappingfile =~ /^(.+?)\/[^\/]+$/;
  $self->logDebug( "parentdir", $parentdir );
  File::Path::mkpath( $parentdir ) if not -d $parentdir;

  my $contents = qq{[
  {
    "DeviceName": "/dev/sda1",
    "Ebs": {
      "DeleteOnTermination": true,
      "VolumeSize": $disksize
    }
  }
]};

  return $self->printToFile($mappingfile, $contents);
}

method getWorkflowDir ( $stageobject ) {
  # $self->logDebug("stageobject", $stageobject);
  my $userdir         = $self->conf()->getKey( "core:USERDIR" );
  my $username        = $stageobject->{ username };
  my $coredir         = $self->conf()->getKey( "core:DIR" );
  my $project         = $stageobject->{ projectname };
  my $workflow        = $stageobject->{ workflowname };
  $self->logDebug( "username", $username );

  my $workflowdir = "$userdir/$username/$coredir/$project/$workflow";
  if ( $username eq "root" ) {
    $workflowdir = "/$username/$coredir/$project/$workflow";
  }
  
  return $workflowdir;
}
	
method getMappingFile {
	my $installdir		=	$self->conf()->getKey( "core:INSTALLDIR" );
	my $targetdir		=	"$installdir/conf/.aws";
    $self->logDebug("targetdir", $targetdir);
	`mkdir -p $targetdir` if not -d $targetdir;

	#my $mappingfile		=	"$targetdir/auth.sh";
	my $mappingfile		=	"$targetdir/mapping.json";
	$self->logDebug("mappingfile", $mappingfile);

	return	$mappingfile;
}

method parseLaunchOutput ($output) {
	# $self->logDebug("output", $output);
	my ($id)	=	$output	=~ /"InstanceId":\s+"(\S+)"/ms;
	#$self->logDebug("id", $id);
	
	return $id;
}

method parseInstanceList ($output) {
	#$self->logDebug("output", $output);
	return if not defined $output or $output eq "";
    
    my $parser = JSON->new();
    my $hash = $parser->decode($output);
    #$self->logDebug("hash", $hash);
    my $reservations = $hash->{"Reservations"};
    $self->logDebug("#. reservations", scalar(@$reservations));

    my $instancehash = {};
    foreach my $reservation ( @$reservations ) {
        my $instances = $reservation->{"Instances"};
        #$self->logDebug("#. instances", scalar(@$instances));
        foreach my $instance ( @$instances ) {
            my $instanceid = $instance->{InstanceId};
            #$self->logDebug("instanceid", $instanceid);
            $instancehash->{$instanceid} = $instance;
        }
    }
    
	return $instancehash;
}

#method deleteNode ($authfile, $instanceid) {
method deleteNode ($instanceid) {
	$self->logDebug("instanceid", $instanceid);
    
    my $authfile    =   $self->printAuthFile();
	$self->logDebug("authfile", $authfile);
    
    my $keypair         =   $self->conf()->getKey( "core:KEYPAIR" );
    my $availabilityzone=   $self->conf()->getKey( "core:AVAILABILITYZONE" );
    my $region          =   $self->conf()->getKey( "core:REGION" );

	my $command		=	qq{AWS_CONFIG_FILE=$authfile && /usr/local/bin/aws ec2 terminate-instances \\
--instance-ids $instanceid \\
--region $region };
    $self->logDebug("command", $command);
    
    my ($out, $err)	=	$self->runCommand($command);
	$self->logNote("out", $out);
	$self->logNote("err", $err);
	
	my $instancehash = $self->getInstance($instanceid, $region);	
	my $state	=	$instancehash->{State}->{Name};	
	$self->logDebug("state", $state);
	
	my $success = 0;
	$success = 1 if defined $state and $state eq "terminated" or $state eq "shutting-down";

	return $success;
}


method getInstance ($instanceid, $region) {	
    $self->logDebug("instanceid", $instanceid);

	#my $command		=	qq{. $authfile && aws ec2 describe-instances};
	my $command		=	qq{aws ec2 describe-instances \\
--instance-ids $instanceid \\
--region $region};
	my ($out, $err)	=	$self->runCommand($command);
	$self->logDebug("out", $out);
	$self->logDebug("err", $err);
	
    my $parser = JSON->new();
    my $object = $parser->decode($out);
    my $reservations = $object->{Reservations};
    return undef if not defined $reservations;
    
    my $instances = $$reservations[0]->{Instances};
    $self->logDebug("instances", $instances);
    return undef if not defined $instances;
    return undef if scalar(@$instances) == 0;

    return $$instances[0];    
}

#method getInstances ($authfile) {
	#$self->logDebug("authfile", $authfile);
method getInstances {
	
	#my $command		=	qq{. $authfile && aws ec2 describe-instances};
	my $command		=	qq{aws ec2 describe-instances};
	my ($out, $err)	=	$self->runCommand($command);
	#$self->logDebug("out", $out);
	#$self->logDebug("err", $err);
	
	return $self->parseInstanceList($out);
}

method printToFile ($file, $text) {
	$self->logCaller("");
    $self->logDebug("file", $file);
	$self->logDebug("substr text", substr($text, 0, 100));

    open(FILE, ">$file") or die "Can't open file: $file\n";
    print FILE $text;    
    close(FILE) or die "Can't close file: $file\n";
}

method getFileContents ($file) {
	$self->logNote("file", $file);
	open(FILE, $file) or $self->logCritical("Can't open file: $file") and exit;
	my $temp = $/;
	$/ = undef;
	my $contents = 	<FILE>;
	close(FILE);
	$/ = $temp;

	return $contents;
}

method runCommand ($command) {
	$self->logDebug("command", $command);
	my $stdoutfile = "/tmp/$$.out";
	my $stderrfile = "/tmp/$$.err";
	my $output = '';
	my $error = '';
	
	#### TAKE REDIRECTS IN THE COMMAND INTO CONSIDERATION
	if ( $command =~ />\s+/ ) {
		#### DO NOTHING, ERROR AND OUTPUT ALREADY REDIRECTED
		if ( $command =~ /\s+&>\s+/
			or ( $command =~ /\s+1>\s+/ and $command =~ /\s+2>\s+/)
			or ( $command =~ /\s+1>\s+/ and $command =~ /\s+2>&1\s+/) ) {
			return `$command`;
		}
		#### STDOUT ALREADY REDIRECTED - REDIRECT STDERR ONLY
		elsif ( $command =~ /\s+1>\s+/ or $command =~ /\s+>\s+/ ) {
			$command .= " 2> $stderrfile";
			$output		= `$command`;
			$error 		= `cat $stderrfile`;
		}
		#### STDERR ALREADY REDIRECTED - REDIRECT STDOUT ONLY
		elsif ( $command =~ /\s+2>\s+/ or $command =~ /\s+2>&1\s+/ ) {
			$command .= " 1> $stdoutfile";
			print `$command`;
			$output = `cat $stdoutfile`;
		}
	}
	else {
		$command .= " 1> $stdoutfile 2> $stderrfile";
		print `$command`;
		$output = `cat $stdoutfile`;
		$error = `cat $stderrfile`;
	}
	
	$self->logNote("output", $output) if $output;
	$self->logNote("error", $error) if $error;
	
	##### CHECK FOR PROCESS ERRORS
	$self->logError("Error with command: $command ... $@") and exit if defined $@ and $@ ne "" and $self->can('warn') and not $self->warn();

	#### CLEAN UP
	`rm -fr $stdoutfile`;
	`rm -fr $stderrfile`;
	chomp($output);
	chomp($error);
	
	return $output, $error;
}



} #### END


