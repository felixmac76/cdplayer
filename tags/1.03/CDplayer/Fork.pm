# CD Player Plugin for SqueezeCenter

# Copyright (C) 2008 Bryan Alton, Ian Parkinson and others
# All rights reserved.

# This program is free software; you can redistribute it and/or
# modify it under the same terms as Perl itself.



# Object that allows lengthy processes to be run forked.
# This is particularly useful for invoking system commands
# that we can't break up using SqueezeCenter's usual
# cooperative multitasking stuff. However it does effectively
# wind up forking all of SqueezeCenter, so should probably
# be used only sparingly.

use strict;

package Plugins::CDplayer::Fork;
use Slim::Utils::Log;
use Slim::Utils::Prefs;

my $log = Slim::Utils::Log::logger("plugin.cdplayer");

my $forkcount   = 1;
my $prefsServer = preferences('server');
my $osdetected  = Slim::Utils::OSDetect::OS();

sub new
{
	my($class, %cnf) = @_;

	my $command            = delete $cnf{command};
	my $params             = delete $cnf{params};
	my $completionCallback = delete $cnf{completionCallback};
	my $completionParam    = delete $cnf{completionParam};
	my $completionStatusTest = delete $cnf{completionStatusTest};
	my $pollingInterval    = delete $cnf{pollingInterval};
 
	my $self = bless {
		command              => $command,
		params               => $params,
		completionCallback   => $completionCallback,
		completionParam      => $completionParam,
		completionStatusTest => $completionStatusTest,
		pollingInterval      => $pollingInterval,
		output               => "",
	}, $class;

	my $forkout      = File::Spec::Functions::catfile($prefsServer->get('cachedir'),"Forkoutput$forkcount.txt");
	$self->{forkout} = $forkout;

	my $exec = Slim::Utils::Misc::findbin($command);

	if ($osdetected eq 'win') {
      # On Windows, we write a .bat file so that we can use shell redirection
		my $forkcmdbat = File::Spec::Functions::catfile($prefsServer->get('cachedir'),"forkcmd$forkcount.bat");

		open(BATFILE, "> $forkcmdbat");
		print BATFILE "\"$exec\" $params 2> \"$forkout\"" ;
		close(BATFILE);
		$self->{syscommand}            = "C:\\Windows\\system32\\cmd.exe /C \"$forkcmdbat\" ";
		$self->{batfile}               = $forkcmdbat;
		$self->{completionStatusTest}  = $completionStatusTest;
		$log->debug("Batch file line:>>>". "\"$exec\" $params 2> \"$forkout\"" . "<<<" );
	}
	elsif ($osdetected eq 'unix') {  # Linux: redirect all command output to the "forkout" file
		$self->{syscommand} = "exec \"$exec\" $params  2> \"$forkout\"";
	} 
	else { # osx platform, For now treat as Linux
		$self->{syscommand} = "\"$exec\" $params 2> \"$forkout\"";
	}

	$forkcount++;
	return $self;
}

sub go
{
	my $self = shift;
	$log->debug("Fork executing '".$self->{command}."' with '".$self->{params}."'");
	$log->debug("Fork actual executing '".$self->{syscommand}."'");
	my $forkout    = $self->{forkout};
	my $syscommand = $self->{syscommand};
    
	unlink $forkout;

	$self->{proc} = Proc::Background->new($syscommand) || $log->debug("Child task forked: failed: $!");

	$log->debug("Child task (". $self->{proc}->pid .") forked: " . $syscommand);
	if ($self->{proc}->alive ){
		$log->debug("Child task is alive ");
	} else {
    		$log->debug("Child task has died/completed at startup");
  	}

  # Set up the callback
  	my $interval = $self->{pollingInterval};
  	Slim::Utils::Timers::setTimer($self,
  	                              Time::HiRes::time()+$self->{pollingInterval},
  	                              \&checkFork, ($self)
  	                              );
}

# Gets invoked by the Timer service every pollingInterval.
# Check for any more output from the forked task
sub checkFork()
{
	my $self = shift;
	my $done=0; 

	my $proc = $self->{proc};
	my $logfile;

	if ($proc->alive ) {
    # Use the callback Status test for time when cdda2wav prompts user for CD
		my $callback=$self->{completionStatusTest};
		if (defined($callback )) {
			my $param=$self->{completionParam};
			&$callback($self,$param);
		}
	}
	else {
		my $output;
		my $pid = $proc->pid;
		$log->debug("Forked task $pid is not alive");
    		open ($logfile, $self->{forkout} ) or  $log->debug("Fork $pid dead: Can't open ". $self->{forkout});
    		while (my $line = <$logfile>) {
      			$log->debug("FORK $pid : $line");
      			$output .= $line;
		}

		$self->{output} = $output;         
		close($logfile);      
		$log->debug("Forked task complete, invoking callback");

	 	my $callback=$self->{completionCallback};
		my $param=$self->{completionParam};
		&$callback($param, $output);

		$done=1;
    
		$log->debug("Deleting Bat and output files ". $self->{forkout});
		unlink $self->{forkout};
		if ($self->{batfile}) { unlink $self->{batfile}; } ;
	};

	if (!$done) {
		my $interval = $self->{pollingInterval};
		Slim::Utils::Timers::setTimer($self,
                	                  Time::HiRes::time()+$self->{pollingInterval},
                        	          \&checkFork, ($self)
                          	        );
  	} ;
}

1;
  