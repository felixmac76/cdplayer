# CD Player Plugin for SqueezeCenter

# Copyright (C) 2008 Bryan Alton and others
# All rights reserved.

# This program is free software; you can redistribute it and/or
# modify it under the same terms as Perl itself.

package Plugins::CDplayer::Settings;

use strict;
use base qw(Slim::Web::Settings);

use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Player::Client;
use Slim::Utils::OSDetect;

my $prefs = preferences('plugin.cdplayer');
my $log   = logger('plugin.cdplayer');

my $osdetected = Slim::Utils::OSDetect::OS();

# Mask number is soted as decimal but treated as ocatl because of way 
# the preferecne code dores initial display of values.
# This should be changed to string and File::chmod as user can enter non octal values.

my %defaults = (
	device 	   => '/dev/cdrom',
	pausestop  => 1,
	cddbinexact  => 1,
	amazonlocale    => 0,
	usemusicbrainz => 0,   # Use CDDB database
	accesskeyid     => undef,	
	secretkey       => undef,
);


# List of CDROM devices in Windows
my %cdromDeviceList;


$prefs->migrate(2, sub {
	$prefs->set('amazonlocale', 0 );
	1;
});

$prefs->migrate(3, sub {
	$prefs->set('accesskeyid', undef);
	$prefs->set('secretkey', undef);
	1;
});




sub new {
	my $class = shift;

	$class->SUPER::new;
}

sub name {
# assumes at least SC 7.0
	if ( substr($::VERSION,0,3) lt 7.4 ) {
		return Slim::Web::HTTP::protectName('PLUGIN_CDPLAYER');
	} else {
	    # $::noweb to detect TinySC or user with no web interface
	    if (!$::noweb) {
		return Slim::Web::HTTP::CSRF->protectName('PLUGIN_CDPLAYER');
	    }
	}


}

sub page {

# assumes at least SC 7.0
	if ( substr($::VERSION,0,3) lt 7.4 ) {
		return Slim::Web::HTTP::protectURI('plugins/CDplayer/settings/basic.html');
	} else {
	    # $::noweb to detect TinySC or user with no web interface
	    if (!$::noweb) {
		return Slim::Web::HTTP::CSRF->protectURI('plugins/CDplayer/settings/basic.html');
	    }
	}



}

sub prefs {
	$log->debug("Prefs called");
	return ($prefs, qw( device cddevice pausestop usemusicbrainz cddbinexact amazonlocale accesskeyid secretkey ));
}

sub handler {
	my ($class, $client, $params) = @_;
	$log->debug("CDplayer::Settings->handler() called.");
	if ($params->{'saveSettings'}) {
		$prefs->set('cddevice',  $params->{'pref_cddevice'});
		$prefs->set('pausestop', $params->{'pref_pausestop'});
		$prefs->set('cddbinexact', $params->{'pref_cddbinexact'});
		$prefs->set('usemusicbrainz', $params->{'pref_usemusicbrainz'});

	}

	if ($osdetected eq 'win') {
		$params->{'underlyingos'} = 1;
		$params->{'cddevicelist'} = cdromListAsHash();
	} elsif ($osdetected eq 'mac')  {
		$params->{'underlyingos'} = 2;
		$params->{'cddevicelist'} = cdromListAsHash();
	} else {
		$params->{'underlyingos'} = 0;
		$params->{'cddevicelist'} = {'XXXXXX' => 'Not used on Linux / OSX'};
	};

	return $class->SUPER::handler( $client, $params );
}

sub setDefaults {
	my $force = shift;

	foreach my $key (keys %defaults) {
		if (!defined($prefs->get($key)) || $force) {
			$log->debug("Missing pref value: Setting default value for $key: " . $defaults{$key});
			$prefs->set($key, $defaults{$key});
		}
	}

	if ($osdetected eq 'unix') {
		$prefs->set('cddevice', 'XXXXXX');
		$log->debug("Setting default value for Linux cddevice - unassigned (XXXXXX)" );
	} elsif ($osdetected eq 'mac') {
		$prefs->set('cddevice', 'IODVDServices');
		$log->debug("Setting default value for OSX cddevice " . $prefs->get('cddevice') );
	}
}

sub cdromListAsHash()
{
	return \%cdromDeviceList;
}

sub buildCdromListAsHash()
{
	my $self = shift;

# In Future this can be used ti buidl a list of suitable Linux CDROM drives
# but at present user will use device entry box in Settings

	if ( $osdetected eq 'unix' ) {
		undef %cdromDeviceList ;
	    	$cdromDeviceList{"XXXXXX"} = 'Not used in Linux';
		return;
	} elsif ( $osdetected eq 'win' ) {

		undef %cdromDeviceList ;
		$cdromDeviceList{"XXXXXX"} = 'Unassigned';
	
		my $command    = "cdda2wav";
		my $cmdparams  = " -scanbus ";

		my $fork = Plugins::CDplayer::Fork->new(command    => $command,
						params             => $cmdparams,
						completionCallback => \&processDeviceList,
						completionParam    => $self,
						pollingInterval    => 1);
	  

  		$fork->go();
  		$fork->{proc}->wait();
	} else {  # OSX branch
		%cdromDeviceList = (
			'IOCompactDiscServices'	 =>  'CDROM/CDRW drive',
			'IODVDServices'		 =>  'DVDROM-DVDRW drive',
			'IOCompactDiscServices/0'=>  '1st CDROM/CDRW drive',
			'IODVDServices/0'	 =>  '1st DVD-ROM/DVDRW drive',
			'IOCompactDiscServices/1' =>  '2nd CDROM/CDRW drive',
			'IODVDServices/1'	 =>  '2nd DVD-ROM/DVDRW drive',
		);

	}
}

sub processDeviceList()
{
	my $self=shift;
	my $response=shift;

# Significant Output of cdda2wav -scanbus looks like the following
#        0,0,0     0) 'SONY    ' 'DVD RW DW-Q120A ' 'PYS2' Removable CD-ROM
#        0,1,0     1) *
#        0,6,0     6) *
#        0,7,0     7) HOST ADAPTOR
#scsibus1:
#        1,0,0   100) 'SAMSUNG ' 'SP2504C         ' 'VT10' Disk
#        1,1,0   101) *
#        1,6,0   106) *
#        1,7,0   107) HOST ADAPTOR
	my @outscanbus = split(/\n/,$response);
	foreach my $line (@outscanbus) {
		my @chunks = split " ",$line;
		if ($line =~ m/^\s*(\d+,\d+,\d+)\s*(\d+)\)\s*(.*?)\s*$/) {
			my @bits = split "'",$3;
			if ($bits[6] eq ' Removable CD-ROM') {
				$cdromDeviceList{"$1"} = $bits[1] . ' ' .$bits[3] ;
					$log->debug("Adding valid CDROM $1  (".$cdromDeviceList{"$1"} .")");  				
			} 
		}	
	}

#  Special setting of Windows CDROM device cddevice

    	if (!defined($prefs->get('cddevice')) ) {
# If only one real CDRom device - then use it as default
		if ((scalar keys %cdromDeviceList) == 2) {  
			foreach (keys %cdromDeviceList) {
				if ( $_ ne 'XXXXXX') {
					$prefs->set('cddevice', $_);
					$log->debug("Setting default value for Windows cddevice to \'" . $_  . "\'  value=\'". $cdromDeviceList{"$_"}. "\' ");
					last;
				}
        		}
		}
		else {
			$prefs->set('cddevice', 'XXXXXX');
			$log->debug("Setting default value for Windows cddevice - unassigned (XXXXXX)" );
		}
	}

}


sub init {
	my $self = shift;
	$log->debug("Initializing settings");
	$self->buildCdromListAsHash();
	setDefaults(0);
}

1;
