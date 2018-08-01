use MooseX::Declare;

=head2

	PACKAGE		Virtual::Aws
	
    VERSION:        0.01

    PURPOSE
  
        1. UTILITY FUNCTIONS TO ACCESS A MYSQL DATABASE

=cut 

use strict;
use warnings;
use Carp;

#### INTERNAL MODULES use FindBin qw($Bin); use lib "$Bin/../../";

class Virtual::Aws with (Util::Logger, Web::Cloud::Aws) {

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

#method launchNode ($authfile, $amiid, $maxnodes, $instancetype, $userdatafile, $keypair, $workflow) {
method launchNode ($workobject, $instanceobject, $amiid, $maxnodes, $instancetype, $instancename, $disksize) {
	$self->logDebug("amiid", $amiid);
    $self->logDebug("instancename", $instancename);

 #    my $disksize = $instanceobject->{"disk"};
	# $self->logDebug("disksize", $disksize);

    my $authfile        =   $self->printAuthFile();
	$self->logDebug("authfile", $authfile);
    
    my $userdatafile    =   $self->printUserDataFile($workobject);
    $self->logDebug("userdatafile", $userdatafile);
    
    my $mappingfile     =   $self->printMappingFile($disksize);
    $self->logDebug("mappingfile", $mappingfile);

    my $keypair     =   $self->conf()->getKey("aws", "KEYPAIR");
    my $availabilityzone=   $self->conf()->getKey("aws", "AVAILABILITYZONE");
    my $region      =   $self->conf()->getKey("aws", "REGION");
	my $vpc		    =	$self->conf()->getKey("aws", "VPC");
	my $securitygroup =	$self->conf()->getKey("aws", "SECURITYGROUP");
	my $subnet      =	$self->conf()->getKey("aws", "SUBNET");
    $self->logDebug("vpc", $vpc);
    $self->logDebug("securitygroup", $securitygroup);
    $self->logDebug("subnet", $subnet);
    
    my $aws = $self->getAws();
	my $command	=	qq{export AWS_CONFIG_FILE=$authfile && $aws ec2 run-instances \\
--image-id $amiid \\
--instance-type $instancetype \\
--user-data file://$userdatafile \\
--block-device-mappings file://$mappingfile \\\n};

    my $runinstances = $self->conf()->getKey("aws", "RUNINSTANCES");
    $self->logDebug("runinstances", $runinstances);
    for my $parameter ( keys %$runinstances ) {
		$self->logDebug("parameter", $parameter);
		my $string = "";
		my $ref = ref($runinstances->{$parameter});
		$self->logDebug("ref", $ref);
		if ( $ref eq "ARRAY" ) {
			foreach my $entry ( @{$runinstances->{$parameter}} )	{
				$string .= " $entry";
			}
		}
		else {
			$string = $runinstances->{$parameter};
		}

		$command .= qq{--$parameter $string \\\n};
    }

	$self->logDebug("command", $command);

	my ($out, $err) 	=	$self->runCommand($command);
	$self->logDebug("out", $out);
	$self->logDebug("err", $err);

	my $instanceid	=	$self->parseLaunchOutput($out);
	$self->logDebug("id", $instanceid);
	
    my $tags = "Key=Name,Value=$instancename";
    $self->setTags($instanceid, $region, $tags);
    
	return $instanceid;
}

method getAws {
    my $aws = "/usr/local/bin/aws";
    $aws = "/usr/bin/aws" if not -f $aws;
    $self->logDebug("aws", $aws);

    return $aws;
}

method setTags ($instanceid, $region, $tags) {
    $self->logDebug("instanceid", $instanceid);
    $self->logDebug("tags", $tags);
    
    my $aws = $self->getAws();
    my $command = qq{$aws ec2 create-tags \\
--resources $instanceid \\
--region $region \\
--tags $tags};

	my ($out, $err) 	=	$self->runCommand($command);
	$self->logDebug("out", $out);
	$self->logDebug("err", $err);

    return ($out, $err);
}

method printUserDataFile ($workobject) {
	$self->logDebug("workobject", $workobject);

	#		GET PACKAGE INSTALLDIR
	my $package			=	$workobject->{package};
	my $version			=	$workobject->{version};
    $self->logDebug("package", $package);
	$self->logDebug("version", $version);
	
    #### SET WORKOBJECT DIRECTORIES
	my $installdir		=	$self->getInstallDir($package);
	$self->logDebug("installdir", $installdir);

	#### GET PREDATA AND POSTDATA
	my $predata			=	$self->getPreData($installdir, $version);
	my $postdata			=	$self->getPostData($installdir, $version);
	#$self->logDebug("BEFORE INSERT predata", $predata);
	#$self->logDebug("BEFORE INSERT postdata", $postdata);
    $predata = $self->insertKeyValues($predata);
    $postdata = $self->insertKeyValues($postdata);
	#$self->logDebug("AFTER INSERT predata", $predata);
	#$self->logDebug("AFTER INSERT postdata", $postdata);

    #### GET USERDATA FILE
	my $userdatafile		= 	$self->getUserDataFile($workobject);
    
	#### GET TEMPLATE
	my $templatefile	=	$self->getTemplateFile($installdir, $version);
	$self->logDebug("templatefile", $templatefile);
	my $template		=	$self->getFileContents($templatefile);
	foreach my $key ( keys %$workobject ) {
		my $templatekey	=	uc($key);
		my $value	=	$workobject->{$key};
		#$self->logDebug("substituting key $key value '$value' into template");
		$template	=~ s/<$templatekey>/$value/msg;
	}

	#### ADD PREDATA AND POSTDATA	
	$template	=~ s/<PREDATA>/$predata/msg if defined $predata;
	$template	=~ s/<POSTDATA>/$postdata/msg if defined $postdata;
	
	# PRINT TEMPLATE
	$self->printToFile($userdatafile, $template);

    return $userdatafile;
}

method getUserDataFile ($workobject) {
    $self->logDebug("workobject", $workobject);

	my $package			=	$workobject->{package};
	my $username		=	$workobject->{username};
	my $project			=	$workobject->{project};
	my $workflow		=	$workobject->{workflow};

	my $basedir			=	$self->conf()->getKey("agua", "INSTALLDIR");
    my $targetdir	=	"$basedir/conf/.aws";
    `mkdir -p $targetdir` if not -d $targetdir;
	my $userdatafile		=	"$targetdir/$username.$project.$workflow.sh";
	$self->logDebug("userdatafile", $userdatafile);
    
    return $userdatafile;
}

method getPreData ($installdir, $version) {
	my $predatafile		=	"$installdir/data/sh/predata";
	$self->logDebug("predatafile", $predatafile);
	
	return "" if not -f $predatafile;
	
	my $predata			=	$self->getFileContents($predatafile);

	return $predata;
}

method getPostData ($installdir, $version) {
	my $postdatafile		=	"$installdir/data/sh/postdata";
	$self->logDebug("postdatafile", $postdatafile);
	
	return "" if not -f $postdatafile;
	
	my $postdata			=	$self->getFileContents($postdatafile);

	return $postdata;
}

method getTemplateFile ($installdir, $version) {
	$self->logDebug("installdir", $installdir);
	
	return "$installdir/data/sh/userdata.sh";
}

method insertKeyValues ($template) {
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
	my $accesskeyid		=	$self->conf()->getKey("aws", "AWSACCESSKEYID");
	my $secretaccesskey =	$self->conf()->getKey("aws", "AWSSECRETACCESSKEY");

    my $contents = qq{[default]
aws_access_key_id=$accesskeyid
aws_secret_access_key=$secretaccesskey
};
	
	$self->printToFile($authfile, $contents);

	return $authfile;
}

method getAuthFile {
	my $installdir		=	$self->conf()->getKey("agua", "INSTALLDIR");
	my $targetdir		=	"$installdir/conf/.aws";
    $self->logDebug("targetdir", $targetdir);
	`mkdir -p $targetdir` if not -d $targetdir;

	#my $authfile		=	"$targetdir/auth.sh";
	my $authfile		=	"$targetdir/credentials";
	$self->logDebug("authfile", $authfile);

	return	$authfile;
}

method printMappingFile ($disksize) {
    $self->logDebug("disksize", $disksize);
	#### GET AUTH FILE
	my $mappingfile		=	$self->getMappingFile();
    $self->logDebug("mappingfile", $mappingfile);
    
    my $contents = qq{[
  {
    "DeviceName": "/dev/sda1",
    "Ebs": {
      "DeleteOnTermination": true,
      "VolumeSize": $disksize
    }
  }
]
};
	
	$self->printToFile($mappingfile, $contents);

	return $mappingfile;
}

method getMappingFile {
	my $installdir		=	$self->conf()->getKey("agua", "INSTALLDIR");
	my $targetdir		=	"$installdir/conf/.aws";
    $self->logDebug("targetdir", $targetdir);
	`mkdir -p $targetdir` if not -d $targetdir;

	#my $mappingfile		=	"$targetdir/auth.sh";
	my $mappingfile		=	"$targetdir/mapping.json";
	$self->logDebug("mappingfile", $mappingfile);

	return	$mappingfile;
}

method parseLaunchOutput ($output) {
	#$self->logDebug("output", $output);
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
    
    my $keypair         =   $self->conf()->getKey("aws", "KEYPAIR");
    my $availabilityzone=   $self->conf()->getKey("aws", "AVAILABILITYZONE");
    my $region          =   $self->conf()->getKey("aws", "REGION");

	my $command		=	qq{export AWS_CONFIG_FILE=$authfile && /usr/local/bin/aws ec2 terminate-instances \\
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


method getInstallDir ($packagename) {
	$self->logDebug("packagename", $packagename);

	my $packages = $self->conf()->getKey("packages:$packagename", undef);
	$self->logDebug("packages", $packages);
	my $version	=	undef;
	foreach my $key ( %$packages ) {
		$version	=	$key;
		last;
	}

	my $installdir	=	$packages->{$version}->{INSTALLDIR};
	$self->logDebug("installdir", $installdir);
	
	return $installdir;
}


} #### END


