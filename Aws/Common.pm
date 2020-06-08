package Virtual::Aws::Common;
use Moose::Role;
use Method::Signatures::Simple;

use strict;
use warnings;

  
method getAws {
  my $aws = "/usr/local/bin/aws";
  $aws = "/usr/bin/aws" if not -f $aws;
  $self->logDebug("aws", $aws);

  return $aws;
}

method runCommand ($command) {
  $self->logDebug("command", $command);
  my $stdoutfile = "/tmp/$$.out";
  my $stderrfile = "/tmp/$$.err";
  my $stdout = '';
  my $stderr = '';
  
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
      $stdout   = `$command`;
      $stderr    = `cat $stderrfile`;
    }
    #### STDERR ALREADY REDIRECTED - REDIRECT STDOUT ONLY
    elsif ( $command =~ /\s+2>\s+/ or $command =~ /\s+2>&1\s+/ ) {
      $command .= " 1> $stdoutfile";
      print `$command`;
      $stdout = `cat $stdoutfile`;
    }
  }
  else {
    $command .= " 1> $stdoutfile 2> $stderrfile";
    print `$command`;
    $stdout = `cat $stdoutfile`;
    $stderr = `cat $stderrfile`;
  }
  
  $self->logNote("stdout", $stdout) if $stdout;
  $self->logNote("stderr", $stderr) if $stderr;
  
  ##### CHECK FOR PROCESS ERRORS
  $self->logError("Error with command: $command ... $@") and exit if defined $@ and $@ ne "" and $self->can('warn') and not $self->warn();

  #### CLEAN UP
  `rm -fr $stdoutfile`;
  `rm -fr $stderrfile`;
  chomp($stdout);
  chomp($stderr);
  
  return $stdout, $stderr;
}



1;