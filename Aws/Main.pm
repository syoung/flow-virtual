use MooseX::Declare;

=head2

	PACKAGE		Virtual::Aws::Main
	 
  PURPOSE

  Launch, monitor and terminate AWS VMs

=cut 

use strict;
use warnings;
use Carp;
use File::Path qw(make_path);


class Virtual::Aws::Main with (Util::Logger, Virtual::Aws::Common) {

#### EXTERNAL MODULES
use JSON;

#### INTERNAL MODULES
use Virtual::Aws::Volume;

# Ints
has 'tries'     => ( isa => 'Int', is => 'rw', default => 20 );
has 'sleep'     => ( isa => 'Int', is => 'rw', default => 5 );
has 'log'		    =>  ( isa => 'Int', is => 'rw', default => 2 );  
has 'printlog'	=>  ( isa => 'Int', is => 'rw', default => 2 );

# Strings

# Objects
has 'conf'			=> ( 
  isa => 'Conf::Yaml', 
  is => 'rw', 
  required	=>	0
);

has 'ssh'			=> ( 
  isa => 'Util::Remote::Ssh', 
  is => 'rw', 
  lazy	=>	1, 
  builder	=>	"setSsh"	
);

has 'volume'  => (
  isa => 'Virtual::Aws::Volume',
  is  => 'rw',
  lazy  =>  1, 
  builder  =>  "setVolume"
);


method BUILD ($args) {
	$self->initialise($args);
}

method initialise ($args) {
	# $self->logNote("");
}

method setSsh( $profilehash ) {
  my $ssh  = Util::Remote::Ssh->new({
    conf          =>  $self->conf(),
    log           =>  $self->log(),
    printlog      =>  $self->printlog()
  });

  $ssh->setUp( $profilehash );

  $self->ssh( $ssh );  
}

method setVolume () {
  my $volume = Virtual::Aws::Volume->new(
    ssh       =>  $self->ssh(),
    logfile   =>  $self->logfile(),
    log       =>  $self->log(),
    printlog  =>  $self->printlog()
  );

  $self->logDebug("volume: $volume");

  return $self->volume( $volume );
}

method getNodeInfo ( $stageobject ) {
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

  #### ADD VARIABLES TO profilehash
  $stageobject->profilehash()->{ instance } = {};
  $stageobject->profilehash()->{ instance }->{ id } = $instanceid;
  $stageobject->profilehash()->{ instance }->{ name } = $instancename;
  $stageobject->profilehash()->{ instance }->{ ipaddress } = $ipaddress;  
  $self->logDebug( "profilehash", $profilehash, 1 );

  return $stageobject;
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
  my $volumesize = $self->getProfileValue( "virtual:volume:size", $profilehash );
  my $volumesnapshot = $self->getProfileValue( "virtual:volume:snapshot", $profilehash );
  $self->logDebug( "volumesnapshot", $volumesnapshot );
  $self->logDebug( "volumesize", $volumesize );

  $self->logDebug( "imageid", $imageid );
  $self->logDebug( "instancetype", $instancetype );
  $self->logDebug( "instancename", $instancename );

  #### CREDENTIALS AND CONFIG FILE
  my $credentialsfile        =   $self->getProfileValue( "virtual:credentialsfile", $profilehash );
  $self->logDebug("credentialsfile", $credentialsfile);
  my $configfile        =   $self->getProfileValue( "virtual:configfile", $profilehash );
  $self->logDebug("configfile", $configfile);

  my $templatefile    =   $self->getProfileValue( "virtual:userdata", $profilehash );
  $self->logDebug("templatefile", $templatefile);

  # #### VOLUME MAPPING FILE
  # my $workflowdir     = $self->getWorkflowDir( $stageobject );
  # my $mappingfile     = "$workflowdir/$stagenumber-$stagename-block-mappings.json";
  # $self->logDebug("mappingfile", $mappingfile);

  # # $self->printMappingFile( $mappingfile, $volumesnapshot, $volumesize );
 
  my $userdatafile = $self->printUserDataFile( $templatefile, $stageobject );
  $self->logDebug( "userdatafile", $userdatafile );

  my $keypair  = $self->getProfileValue( "virtual:keypair", $profilehash );
  my $region  = $self->getProfileValue( "virtual:region", $profilehash );
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

exit;


#### DEBUG
#### DEBUG
#### DEBUG

  my ( $out, $err )   =  $self->runCommand( $command );
  $self->logDebug("out", $out);
  $self->logDebug("err", $err);

  my $parser = JSON->new();
  my $instance = $parser->decode( $out );
  my $instanceid = $instance->{ Instances }[ 0 ]->{ InstanceId };
  my $availabilityzone = $instance->{ Instances }[ 0 ]->{ Placement }->{ AvailabilityZone };
  $self->logDebug( "availabilityzone", $availabilityzone );
  $self->logDebug("instanceid", $instanceid);
  
  my $ipaddress = $self->ipFromInstanceId($instanceid, $credentialsfile, $configfile); 

  # my $instanceid = "i-0434443d7e084c715";
  # my $ipaddress  = "52.91.211.175";
  # my $availabilityzone = "us-east-1c";

  # my $instanceid = "i-0b3c85d1b59a0cfa3";
  # my $ipaddress = "54.86.221.44";
  # my $availabilityzone = "us-east-1a";

  # my $instanceid = "i-04866f42d53b2eada";
  # my $ipaddress = "54.90.190.212";
  # my $availabilityzone = "us-east-1d";

  # my $instanceid = "i-0f38d69878f26083a";
  # my $ipaddress = "52.55.27.42";
  # my $availabilityzone = "us-east-1a";


  $self->logDebug("ipaddress", $ipaddress);
  
  $self->setInstanceName( $instanceid, $instancename );

  #### ADD VARIABLES TO profilehash
  $stageobject->profilehash()->{ instance } = {};
  $stageobject->profilehash()->{ instance }->{ id } = $instanceid;
  $stageobject->profilehash()->{ instance }->{ name } = $instancename;
  $stageobject->profilehash()->{ instance }->{ ipaddress } = $ipaddress;  
  $stageobject->profilehash()->{ instance }->{ availabilityzone } = $availabilityzone;  
  $self->logDebug( "profilehash", $profilehash, 1 );

  $self->waitInstanceStatus( $instanceid, [ "running" ] );

  $self->setSsh( $profilehash );

  $self->mountVolumes( $profilehash, $instanceid, $ipaddress, $availabilityzone );
    
  return $stageobject;
}

method waitInstanceStatus ( $instanceid, $statuses ) {
  $self->logDebug( "instanceid", $instanceid );
  $self->logDebug( "statuses", $statuses );

  my $tries = $self->tries();
  my $sleep = $self->sleep();
  my $counter = 0;
  while ( $counter < $tries ) {

    sleep( $sleep );    
    my $aws = $self->getAws();
    my $command = "$aws ec2 describe-instances --instance-ids $instanceid";
    $self->logDebug( "command", $command );
    my ( $stdout, $stderr ) = $self->runCommand( $command );
    $self->logDebug( "stdout", $stdout );
    $self->logDebug( "stderr", $stderr );

    my $parser = JSON->new();
    my $instance = $parser->decode( $stdout );
    $self->logDebug( "instance", $instance );

    # FORMAT:
    #
    # "Reservations": [
    #   {
    #     "Instances": [
    #       {
    #         "State": {
    #             "Name": "running"
   
    my $currentstatus = $instance->{ Reservations }[ 0 ]->{ Instances }[ 0 ]->{ State }->{ Name };
    $self->logDebug( "currentstatus", $currentstatus );

    foreach my $status ( @$statuses ) {
      if ( $currentstatus eq $status ) {
        return 1;
      }
    }

    $counter++;
  }

  return 1;

}

method mountVolumes ( $profilehash, $instanceid, $ipaddress, $availabilityzone ) {
  $self->logDebug( "profilehash", $profilehash );
  $self->logDebug( "instanceid", $instanceid );
  $self->logDebug( "ipaddress", $ipaddress );
  $self->logDebug( "availabilityzone", $availabilityzone );

  my $volumes = $self->getProfileValue( "virtual:volumes", $profilehash );   
  $self->logDebug( "volumes", $volumes );

  if ( not defined $volumes ) {
    $self->logDebug( "Volumes not defined. Skipping 'mountVolumes'" );
  }

  my $volumer = $self->volume();
  # $self->logDebug( "volumer", $volumer );

  foreach my $volume ( @$volumes ) {
    my $snapshot = $volume->{ snapshot };
    $self->logDebug( "snapshot", $snapshot );
    my $size = $volume->{ size };
    $self->logDebug( "size", $size );
    my $filetype = $volume->{ filetype };
    $self->logDebug( "filetype", $filetype );

    my $volumeid = $volumer->createVolume( $snapshot, $availabilityzone, $size );
    # my $volumeid = "vol-0c5120da52c898d29";
    # my $volumeid = "vol-0ab3a2f5c382ca255";
    $self->logDebug( "volumeid", $volumeid );

    $volumer->waitVolumeStatus( $volumeid, [ "available" ] );

    ####  TO DO: FORMAT VOLUME IF REQUIRED
    # my $format = $volume->{ format };
    # if ( defined $format ) {
    # }

    my $device = $volume->{ device };
    my $mountpoint = $volume->{ mountpoint } || "/mnt";
    $self->logDebug( "device", $device );
    $self->logDebug( "mountpoint", $mountpoint );
    $volumer->createMountPoint( $mountpoint );

    my $success = $volumer->attachVolume( $instanceid, $volumeid, $device, $mountpoint );
    $self->logDebug( "success", $success );
    $self->logCritical( "FAILED TO ATTACH VOLUME" ) if $success == 0;

    $volumer->waitVolumeStatus( $volumeid, [ "attached", "in-use" ] );

    $volumer->mountVolume( $device, $mountpoint, $filetype );
  }
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
    # $self->logDebug("hash", $hash);
  }

  return $hash;
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
	$template = $self->insertWorkflowValues( $template, $workflowobject );
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
  my $userdatafile    = "/$username/$coredir/$project/$workflow/userdata";

  if ( $username ne "root" ) {
     $userdatafile    = "$userdir" . $userdatafile;
  }

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
		my $value = $self->conf()->getKey( "$key:$subkey" );
    
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

method printMappingFile ( $mappingfile, $volumesnapshot, $volumesize ) {
  $self->logDebug( "mappingfile", $mappingfile );
  $self->logDebug( "volumesize", $volumesize );
  
  my ($parentdir) = $mappingfile =~ /^(.+?)\/[^\/]+$/;
  $self->logDebug( "parentdir", $parentdir );
  File::Path::mkpath( $parentdir ) if not -d $parentdir;

  my $contents = qq{[
  {
    "DeviceName": "/dev/sdf",
    "Ebs": {
      "DeleteOnTermination": false,
      "VolumeSize": $volumesize,
      "SnapshotId" : $volumesnapshot
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



} #### END


