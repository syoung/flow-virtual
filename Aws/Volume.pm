use MooseX::Declare;

=head

	CLASS: Volume

	PURPOSE: Create, format and attach/detach volumes on EC2 instances

=cut

class Virtual::Aws::Volume with (Util::Logger, Virtual::Aws::Common) {

# Ints
has 'tries'		=> ( isa => 'Int', is => 'rw', default => 10 );
has 'sleep'		=> ( isa => 'Int', is => 'rw', default => 3 );

# Strings
has 'filetype'		=> ( isa => 'Str|Undef', is => 'rw', default => 'ext3' );

# Objects
has 'head' 			=> ( 
	is =>	'rw', 
	isa => 'Engine::Instance', 
	required	=>	0 
);

has 'ssh'			=> ( 
  isa => 'Util::Remote::Ssh', 
  is => 'rw', 
  lazy	=>	1, 
  builder	=>	"setSsh"	
);

method BUILD ($args) {
	# $self->logDebug( "args", $args );
}

method loadSnapshot ($id, $name, $description) {
	$self->logDebug("id", $id);

	#### NOT YET IMPLEMENTED
	$self->logDebug("NOT YET IMPLEMENTED. RETURNING");
	return;

	return if not defined $self->table()->db();
	
	$self->logDebug("Doing volumeLoaded");
	return if $self->volumeLoaded($id);
	
	$self->logDebug("Doing loadVolume");
	$self->loadVolume($id, $description);	
}

method volumeLoaded ($snapshot) {
	return if not defined $self->table()->db();
	my $query = qq{SELECT 1 FROM volume WHERE snapshot = '$snapshot'};
	return $self->table()->db()->query($query);
}

method loadVolume ($snapshot, $tag) {
	my ($privatekey, $publiccert) = $self->getCertificates();
	my $availzone = $self->conf()->getKey("aws:AVAILABILITYZONE");
	my $size = undef;
	$self->_createVolume($privatekey, $publiccert, $snapshot, $availzone, $size);
}

method createVolume ( $snapshot, $availzone, $size ) {
	$self->logDebug( "snapshot", $snapshot );
	$self->logDebug( "availzone", $availzone );
	$self->logDebug( "size", $size );

	my $aws = $self->getAws();
  my $command = "$aws ec2 create-volume ";
	if ( defined $snapshot and $snapshot ) {
		$command .= "--snapshot-id $snapshot --size $size --availability-zone $availzone";
	}
	else {
		$command .= "--size $size --availability-zone $availzone ";
	}
	$self->logDebug( "command", $command );
	my ( $stdout, $stderr ) = $self->runCommand( $command );
	$self->logDebug( "stdout", $stdout );
	$self->logDebug( "stderr", $stderr );

	$self->logDebug( "stdout", $stdout );
	my ( $volumeid ) = $stdout =~ /"VolumeId": "([^"]+)"/ms;	
	$self->logDebug("volumeid", $volumeid);

	return $volumeid;
}

method formatVolume ($device, $filetype) {
	$self->logDebug("device", $device);
	$self->logDebug("filetype", $filetype);
	
	my $command = "mkfs.$filetype -F $device";
	$self->logDebug("command", $command);
	my $result = `$command`;
	$self->logDebug("result", $result);

	return $result;	
}

method createMountPoint ($mountpoint) {
	my $command = "sudo mkdir -p $mountpoint";
	my ( $stdout, $stderr ) = $self->ssh()->command( $command );
	$self->logDebug( "stdout", $stdout );
	$self->logDebug( "stderr", $stderr );

	# $self->logError("Can't create mountpoint") and exit if not -d $mountpoint;
}

method attachVolume ($instanceid, $volumeid, $device, $mountpoint) {
#### ATTACH A VOLUME TO A DEVICE
	$self->logDebug("instanceid", $instanceid);
	$self->logDebug("volumeid", $volumeid);
	$self->logDebug("device", $device);
	$self->logDebug("mountpoint", $mountpoint);

	my $aws = $self->getAws();
	my $command = "$aws ec2 attach-volume --volume-id $volumeid --instance-id $instanceid --device $device ";
	$self->logDebug("command", $command);
	my ( $stdout, $stderr ) = $self->runCommand($command); 
	$self->logDebug( "stdout", $stdout );

	#### RETURN 0 ON FAILURE
	if ( $stdout eq "" ) {
		return 0;
	}

	#### EXPECTED OUTPUT
	#
	# {
	#    "AttachTime": "2020-05-18T19:32:59.760Z",
	#    "Device": "/dev/xvdf",
	#    "InstanceId": "i-0434443d7e084c715",
	#    "State": "attaching",
	#    "VolumeId": "vol-0c5120da52c898d29"
	# }

  my $parser = JSON->new();
  my $result = $parser->decode( $stdout );
  $self->logDebug( "result", $result );
	if ( $result->{ State } ne "attaching" ) {
		return 0;
	}

	return 1;
}

method waitVolumeStatus ( $volumeid, $statuses ) {
	$self->logDebug( "volumeid", $volumeid );
	$self->logDebug( "statuses", $statuses );

	my $tries = $self->tries();
	my $sleep = $self->sleep();
	my $counter = 0;
	while ( $counter < $tries ) {
		# #### ec2dvol FORMAT:
		#	
		# {
		#     "AttachTime": "2020-05-18T15:46:09.870Z",
		#     "Device": "/dev/xvdf",
		#     "InstanceId": "i-0434443d7e084c715",
		#     "State": "attaching",
		#     "VolumeId": "vol-0219290c2f7f48f78"
		# }

		sleep( $sleep );		
		my $aws = $self->getAws();
		my $command = "$aws ec2 describe-volumes --volume-ids $volumeid";
		$self->logDebug( "command", $command );
		my ( $stdout, $stderr ) = $self->runCommand( $command );
		$self->logDebug( "stdout", $stdout );
		$self->logDebug( "stderr", $stderr );
	  my $parser = JSON->new();
	  my $volume = $parser->decode( $stdout );
	  $self->logDebug( "volume", $volume );

	  my $currentstatus = $volume->{ Volumes }[ 0 ]->{ State };
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

method mountVolume ($device, $mountpoint, $filetype) {
	$self->logDebug("device", $device);
	$self->logDebug("mountpoint", $mountpoint);

	#### MOUNT
	my $command = "sudo mount -t $filetype $device $mountpoint";
	$self->logDebug("command", $command);
	
	my ( $stdout, $stderr ) = $self->ssh()->command( $command );
	$self->logDebug( "stdout", $stdout );
	$self->logDebug( "stderr", $stderr );

	my $result = $stdout;
	$self->logDebug("result", $result);
	
	return $result;
}

method killMountProcesses ($mountpoint) {
	my $command = "lsof +D $mountpoint";
	$self->logDebug("command", $command);
	my $string = `$command`;
	$self->logDebug("string", $string);
	my @lines = split "\n", $string;
	shift @lines;
	foreach my $line ( @lines ) {
		my @elements = split " ", $line;
		next if $elements[0] eq "lsof";
		my $command = "kill -9 $elements[1]";
		$self->logDebug("command", $command);
		`$command`;
	}
}

method unmountVolume ($device, $options) {
	$self->logDebug("device", $device);
	$self->logDebug("options", $options);
	$options = '' if not defined $options;
	my $command = "umount -$options $device";
	$self->logDebug("command", $command);

	my ($result) = $self->runCommand($command);
	$self->logDebug("result", $result);
	
	return $result;
}

method detachVolume ($instanceid, $device, $volumeid) {
#### DETACH AN EXISTING VOLUME
	#### 1. UNMOUNT DEVICE
	$device = $self->alternateDevice($device) if not -f $device;
	my $unmount = "umount $device";
	$self->logDebug("unmount", $unmount);
	my $unmount_success = `$unmount`;
	$self->logDebug("unmount_success", $unmount_success);

	#### 2. DETACH VOLUME
	my $force = 0;
	my $result = $self->_detachVolume($volumeid, $force);
	return 1 if $result eq "available";

	#### 3. DID NOT DETACH SO GO NUCLEAR WITH --force
	$self->logDebug("Simple detach failed. Rerunning detach with '--force'");
	$force = 1;
	$result = $self->_detachVolume($volumeid, $force);
	
	#### 4. CHECK FILESYSTEM FOR ERRORS AFTER USING --force 
	my $check = "fsck -fy $device";
	$self->logDebug("check", $check);
	
	return 1 if $result eq "available";
	return 0;
}

method _detachVolume ($volumeid, $force) {
	my $command = "ec2-detach-volume $volumeid";
	$command = "ec2-detach-volume --force $volumeid " if $force;
	$self->logDebug("command", $command);
	my $output = `$command`;
	$self->logDebug("output", $output);
	my $result = `ec2-describe-volumes $volumeid | cut -f 6`;
	$self->logDebug("result", $result);
	return $result if $result eq "available";
	
	#### 3. KEEP WAITING FOR DETACHED VOLUME TO BECOME 'available'
	my $tries = 8;	#### HEURISTIC
	my $sleep = 3;  ####
	$result = $self->waitDetach($volumeid, $tries, $sleep);
	$self->logDebug("2nd result", $result);
	return $result if $result eq "available";

	return 0;	
}

method waitDetach ($volumeid, $tries, $sleep) {	
	#### WAIT UNTIL THE DETACHING VOLUME IS 'available' TO MAKE SURE IT'S
	#### DETACHING HAS COMPLETED
	my $counter = 0;
	my $detach_success = '';
	while ( $counter < $tries )
	{
		#### FORMAT:
		#### ec2dvol 		
		####		
		#### VOLUME  vol-85f401ed    40      snap-55fe4a3f   us-east-1a      in-use  2010-11-18T19:40:43+0000
		#### ATTACHMENT      vol-85f401ed    i-b6147adb      /dev/sdh        attached        2010-11-18T19:40:49+0000

		sleep($sleep);
		$detach_success = `ec2-describe-volumes $volumeid | cut -f 6`;
		$detach_success =~ s/\s+//g;
		$self->logDebug("counter $counter detach_success", $detach_success);
		$counter = $tries if $detach_success eq "available";
		$counter++;
	}

	return $detach_success;
}

method checkDevice ($device) {
	$device = $self->alternateDevice($device) if not -f $device;
	return $device;
}

method alternateDevice ($device) {
	if ( $device =~ /^\/dev\/sd(.+)/ ) {
		$device = "/dev/xvd$1";
		#$self->logDebug("device: $device");
	}

	return $device;	
}

method setHeadInstance {
	return $self->head() if defined $self->head();

	my $instanceid = $self->runCommand("curl -s http://169.254.169.254/latest/meta-data/instance-id");
	my $head = Engine::Instance->new({
		instanceid	=>	$instanceid,
		privatekey	=>	$self->privatekey(),
		publiccert	=>	$self->publiccert()
	});
	
	$self->head($head);
}

method localOrEC2Ip {
	$self->logDebug("");
	$self->setHeadInstance();
	my $externalip = $self->head()->externalip();
	$self->logDebug("externalip", $externalip);
	if ( not defined $externalip )	{
		$externalip = `hostname`;
		$externalip =~ s/\s+//g;
	}
	$self->logError("External IP not defined") and exit if not defined $externalip;
	$self->logDebug("externalip", $externalip);
	
	return $externalip;
}








1;


}
