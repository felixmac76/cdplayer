# CDhandler part of CDplayer Plugin for SqueezeCenter

# Copyright (C) 2008 Bryan Alton and others
# All rights reserved.

# This program is free software; you can redistribute it and/or
# modify it under the same terms as Perl itself.


package Plugins::CDplayer::CDhandler;

use strict;

use Slim::Utils::Log;
use Slim::Utils::Misc;
use Slim::Utils::Timers;
use Slim::Utils::Strings qw(string);
use Slim::Utils::Prefs;
use File::Spec::Functions qw(:ALL);
use Plugins::CDplayer::Fork;

use XML::Simple;
use URI::Escape;
use Encode;
use Fcntl;

my $log         = logger('plugin.cdplayer');
my $prefsServer = preferences('server');
my $prefs       = preferences('plugin.cdplayer');
my $osdetected  = Slim::Utils::OSDetect::OS();

my $killorphan ;

use constant LOADCD_ERROR_NODBRECORD    =>  1;
use constant LOADCD_ERROR_GOTDBRECORD   =>  2;
use constant LOADCD_ERROR_NONE          =>  0;
use constant LOADCD_ERROR_NOCD          => -1;
use constant LOADCD_ERROR_NODBFETCHFAIL => -2;
use constant LOADCD_ERROR_BUSY		=> -3;

use constant LOADCD_STATE_IDLE               => 0;
use constant LOADCD_STATE_READINGTOC         => 1;
use constant LOADCD_STATE_CHECKING_TOC_READ  => 2;
use constant LOADCD_STATE_KILL_READTOC       => 3;
use constant LOADCD_STATE_READTOC_FAILED     => 4;
use constant LOADCD_STATE_REQUEST_DBREC      => 5;
use constant LOADCD_STATE_REQUEST_DB_ERROR   => 6;
use constant LOADCD_STATE_REQUEST_DB_OK      => 7;
use constant LOADCD_STATE_PROCESS_TOC_RESPONSE => 8;
use constant LOADCD_STATE_PROCESS_COMPLETEDOK => 9;
use constant LOADCD_STATE_PROCESS_COMPLETEDFAIL => 10;


use constant CDDRIVE_FREE => 0;
use constant CDDRIVE_BUSY => 1;

#use constant LOADCD_STATE_  =>1;
#use constant LOADCD_STATE_  =>1;

#
# Max size of Fork log output - normally for 10 track CD with CD-extra about 2500.
# so 25000 is a very large log file compared to normal.
#

use constant MAX_LOG_SIZE => 25000;

my $createToolhelp32Snapshot;
my $process32First;
my $process32Next;
my $closeHandle;

if ($osdetected eq 'win') {
	require Win32;
	require Win32::API;
	require Win32::Process;

	$createToolhelp32Snapshot = Win32::API->new('kernel32','CreateToolhelp32Snapshot',['N','N'],'I');
	if(not defined $createToolhelp32Snapshot) {
		$log->error( "Can't import API createToolhelp32Snapshot: $!");
	}
	$process32First 	= Win32::API->new('kernel32','Process32First',['N','P'],'I');
	if(not defined $process32First) {
		$log->error( "Can't import API process32First: $!");
	}
	$process32Next 	= Win32::API->new('kernel32','Process32Next',['N','P'],'I');
	if(not defined $process32Next) {
		$log->error( "Can't import API process32Next: $!");
	}
	$closeHandle		= Win32::API->new('kernel32', 'CloseHandle',['N'],'I');
	if(not defined $closeHandle) {
		$log->error( "Can't import API closeHandle: $!");
	}
}





sub new
{
	my $class    = shift;

	my $self = bless {
		cdplaying     => 0,
		cduse         => CDDRIVE_FREE,
		loaderror     => LOADCD_ERROR_NONE,
		loadstate     => LOADCD_STATE_IDLE,
		loadclient    => undef,
		loadsuccesscallback => undef,
		loadfailedcallback   => undef,
		loadcallbackparams   => undef,
		firstTrack    => undef,
		lastTrack     => undef,
		mbDiscId      => undef,
		offsets       => undef,
		lengths       => undef,
		durations     => undef,
	}, $class;

	return $self;
}

sub init {
	my $self = shift;
	Slim::Buttons::Common::addMode('loadcd',  $self->getFunctions, sub { $self->setMode(@_) });
}

sub getFunctions {
	my $class = shift;
	return {};
}

sub setMode {
	my $self = shift;
	my $client = shift;
	my $method = shift;

	if ($method eq 'pop') {
		Slim::Buttons::Common::popMode($client);
		return;
	}

	my ($retval, $drivestatus, $errormessage) = cdromstatus($prefs->get('device'));
	if ($retval == 0) {
		my %params = (
			'header'  => "{PLUGIN_CDPLAYER_LOADCD_ERROR} {count}",
			'listRef' => [ string($errormessage) . " ($drivestatus)" ],
		);

		Slim::Buttons::Common::pushModeLeft($client, 'INPUT.Choice', \%params);
		return;
	}

	if ($self->{cduse} == CDDRIVE_BUSY) {
		$log->info("CD drive is currently loading a TOC for another client ");

		my %params = (
			'header'  => "{PLUGIN_CDPLAYER_CD_BUSY} {count}",
			'listRef' => [ string('PLUGIN_CDPLAYER_TRY_AGAIN') ],
		);

		Slim::Buttons::Common::pushModeLeft($client, 'INPUT.Choice', \%params);
		return;
	}

	# give user feedback while loading
	$client->block(string('PLUGIN_CDPLAYER_LOADING_CD'),string('PLUGIN_CDPLAYER_PLEASE_WAIT'));

	$log->info("setmode called");

	if ($self->{cdplaying} == 0) {
		$self->LoadCDandIdentify($client,\&ReadCDTOCSuccessCallback,\&ReadCDTOCFailedCallback, $self);
	} else {
		$log->info("CD playing - so don't reload CD index");
		ReadCDTOCSuccessCallback($self, $client);
	}

}

sub LoadCDandIdentify
{
	my ($self, $client, $callbacksuccess, $callbackerror, $callbackparams) = @_;
	my $device;


	$log->info("Request to load CD and identify");
	bt() if ($log->is_debug) ;
	$log->debug(" cd use is " . $self->{cduse} . " Busy=". CDDRIVE_BUSY);
	
	$self->{loadclient}          = $client;
	$self->{loadsuccesscallback} = $callbacksuccess;
	$self->{loadfailedcallback}  = $callbackerror;
	$self->{loadcallbackparams}  = $callbackparams;
	$self->{cduse} = CDDRIVE_BUSY;

#
#	reset error & state
#
	$self->{loaderror} = LOADCD_ERROR_NONE;
	$self->{loadstate} = LOADCD_STATE_READINGTOC;

	if ($osdetected eq 'win') {
		$device = $prefs->get('cddevice');
	} elsif ($osdetected eq 'unix') {
		$device = $prefs->get('device');
	} else { # OSX
		$device = $prefs->get('cddevice');
	}

	
	my $cmdparams;
	my $command = "cdda2wav";
 
	if ($osdetected eq 'mac') {
		$command = "cdda2wavosx.sh";
	};

#	if ($osdetected ne 'win') {
		$cmdparams  = "device=$device -verbose-level=toc -N -g -J";
#	} else { 
#		$cmdparams  = "-device $device -verbose-level=toc -N -g -J";
#	};
	$log->debug("Create Fork to read CD TOC using cdda2wav on $osdetected device $device ");

	$self->{tocfork} = Plugins::CDplayer::Fork->new(
				command               => $command,
				params                => $cmdparams,
				completionCallback    => \&processCDTOCResponse,
				completionParam       => $self,
				completionStatusTest  => \&cdInfoCompletionTest,
				pollingInterval       => 1);
	  

  	$self->{tocfork}->go();

}

#
# This shouLd be called from Fork and so self point to a Fork Object not a cdinfo.
#
sub cdInfoCompletionTest
{
	my $self=shift;
	my $param = shift;
	my $logfile;
	
	$param->{loadstate} = LOADCD_STATE_CHECKING_TOC_READ;
	open ($logfile, $self->{forkout} ) or  $log->debug("Fork alive: Can't open ". $self->{forkout});

	if (int ((-s $logfile)) > MAX_LOG_SIZE) {
		$log->error("CD TOC log file is too large - pretend no CD error as there may be an undefined problem");
	}

	while (my $line = <$logfile>) {
		if (($line =~ m/load cdrom please and press enter/) || (int ((-s $logfile)) > MAX_LOG_SIZE) ) {
			$log->info(" No CD in drive - cdda2wav is prompting user");

			if ($osdetected eq 'win') {
	        		$log->info("Windows: Time to kill cdda2wav");
#				Proc::Background->new("TASKKILL /F /IM cdda2wav.exe ");
#				kill INT  => $self->{proc}->pid();
				$self->{proc}->die();
				killOrphans();
			} else {
				$log->info(" Linux / OSX - kill cdda2wav process ". $self->{proc}->pid());
				$self->{proc}->die();
			}
			$param->{loadstate} = LOADCD_STATE_KILL_READTOC;
			
		}
	}
	close($logfile); 
}

sub processCDTOCResponse
{
	my $self=shift;
	my $response=shift;

	$self->{loadstate} = LOADCD_STATE_PROCESS_TOC_RESPONSE;
	$self->{cduse} = CDDRIVE_FREE;

	$self->parsetoc($response);

	if ($self->{loaderror} == LOADCD_ERROR_NOCD ) {

		$self->{loadstate} = LOADCD_STATE_READTOC_FAILED;
		$self->{mbbasicrelease} = undef;
		$self->{cddbrec} = undef;
		$log->info("Read CD TOC failed  " . $self->getErrorText() );

		my $callback=$self->{loadfailedcallback};
		&$callback($self->{loadclient} , $self->{loadcallbackparams});
		return;
	} 
#
# Initiate retrieving information from MusicBrainz or CDDB
#
$log->debug ("Prefs UseMusicbrainz = " . $prefs->get('usemusicbrainz'));
	if ( $prefs->get('usemusicbrainz') == 1 ) {
		$self->{cddbrec} = undef;
		my $mbDiscId = $self->computeMBDiscId();
		$log->debug("After compute MB id. Loaderror=". $self->{loaderror} );
		$log->info("Searching MB for release data for $mbDiscId"  );
		my $url="http://musicbrainz.org/ws/1/release/?type=xml&discid=$mbDiscId";
#
# uncommment line below for testing conflict album - multiple albums with same MB Disc Id
#     $url="http://musicbrainz.org/ws/1/release/?type=xml&discid=QtRugoR_rjMVycRKhiOj3jz6RWQ-";
#
		$self->{loadstate} = LOADCD_STATE_REQUEST_DBREC;
		my $http = Slim::Networking::SimpleAsyncHTTP->new(
			\&retrieveMBBasicOK, \&retrieveMBError,
				{
					timeout  => 30,
					cache   => 1,
					self     => $self,
					myclient => $self->{loadclient}
				} 
			);
		$http->get($url);
	} elsif (  $prefs->get('usemusicbrainz') == 0 ) {
		$self->{mbbasicrelease} = undef;

		my ($CddbDiscId , $CddbQueryStr) = $self->computeCDDBDiscId();

#		$self->{loadstate} = LOADCD_STATE_REQUEST_MBREC;
		$log->info("Searching CDDB for release data for $CddbDiscId"  );
		my $cddburl = "http://freedb.freedb.org/~cddb/cddb.cgi?cmd=cddb+query+" . $CddbDiscId . $CddbQueryStr .		
			"&hello=anonymous+localhost+SqueezeCenter+CDplayer1.0&proto=6";
#	Uncomment one of next lines to test UTF-8 representation 
#  		my $cddburl = "http://freedb.freedb.org/~cddb/cddb.cgi?cmd=cddb+query+24037f04+4+150+17532+33767+51227+897&hello=anonymous+localhost+MPlayer+dev-SVN-r26468-4.1.0&proto=6";
#  		my $cddburl = "http://freedb.freedb.org/~cddb/cddb.cgi?cmd=cddb+query+510b0714+20+150+7843+13339+31192+51495+52274+74085+74723+89181+92525+110796+126118+126740+140504+140886+158211+171376+189339+206077+207669+2825&hello=anonymous+localhost+MPlayer+dev-SVN-r26468-4.1.0&proto=6";

		$log->debug("cddb url = $cddburl");

		my $http = Slim::Networking::SimpleAsyncHTTP->new(
			\&retrieveCDDBBasicOK, \&retrieveCDDBError,
				{
					timeout  => 30,
					cache   => 1,
					self     => $self,
					myclient => $self->{loadclient}
				} 
			);

		$http->get($cddburl);
	} else {
		$self->{loadstate} = LOADCD_STATE_REQUEST_DB_OK ;
		$self->{loaderror} = LOADCD_ERROR_NODBRECORD ;
		$log->info("NO DB lookup selected");
		my $callback=$self->{loadsuccesscallback};
		&$callback($self->{loadclient},$self->{loadcallbackparams});
		
	}
}

sub ReadCDTOCFailedCallback
{
	my $client = shift;
	my $cdInfo = Plugins::CDplayer::Plugin::cdInfo();

	$client->unblock();

	my %params = (
		'header'  => "{PLUGIN_CDPLAYER_LOADCD_ERROR} {count}",
		'listRef' => [ $cdInfo->getErrorText() ],
	);

	Slim::Buttons::Common::pushModeLeft($client, 'INPUT.Choice', \%params);
	
}


# Invoked when the CD TOC Query returns
#
#  PArsing should be tested with following (J. Michel Jarre Magentic Fields) - Same DiscID - two releases.
# http://musicbrainz.org/ws/1/release/?type=xml&discid=QtRugoR_rjMVycRKhiOj3jz6RWQ-

sub retrieveMBBasicOK
{
	my $http    = shift;
	my $self    = $http->params('self');
	my $client  = $http->params('myclient');
	my $content = $http->content;

	$self->{loadstate} = LOADCD_STATE_REQUEST_DB_OK;

	$self->{mbbasicrelease} = undef;

	$log->info("Got Basic Release Info from MusicBrainz:");
	$log->debug($content);

	my $mbrec = XMLin($content , KeyAttr=> ['release'], ForceArray=> ['release']);

	$self->{mbbasicrelease} = $mbrec;
	my $release = $mbrec->{'release-list'}->{'release'};

	if (defined($release)   ) {
		$self->{loadstate} = LOADCD_STATE_REQUEST_DB_OK ;
		$self->{loaderror} = LOADCD_ERROR_GOTDBRECORD ;
	} else {
		$self->{loadstate} = LOADCD_STATE_REQUEST_DB_OK ;
		$self->{loaderror} = LOADCD_ERROR_NODBRECORD ;
		$log->info("Basic Release Info - no release info found on MB");
	}

	my $callback=$self->{loadsuccesscallback};
	&$callback($self->{loadclient},$self->{loadcallbackparams});

}

sub retrieveMBError
{
	my $http    = shift;
	my $self    = $http->params('self');
	my $client  = $http->params('myclient');
	my $error   = $http->error;

	$log->info("Error while contacting MusicBrainz: $error");

	$self->{loadstate} = LOADCD_STATE_REQUEST_DB_ERROR ;
	$self->{loaderror} = LOADCD_ERROR_NODBFETCHFAIL ;

	my $callback=$self->{loadfailedcallback};
	&$callback($self->{loadclient},$self->{loadcallbackparams});

}

sub retrieveCDDBBasicOK
{
	my $http    = shift;
	my $self    = $http->params('self');
	my $client  = $http->params('myclient');
	my $content = $http->content;

#	$self->{loadstate} = LOADCD_STATE_REQUEST_FREEDB_OK;

	$self->{cddbbasicrelease} = undef;

	$log->info("Got Basic Release Info from FreeDB.  Code=". $http->code . " Error=". $http->error);
	$log->debug($content);

	if ($http->code == 200) {
		$self->{cddbrec} =  $content;
		$self->{loadstate} = LOADCD_STATE_REQUEST_DB_OK ;
		$self->{loaderror} = LOADCD_ERROR_GOTDBRECORD ;

	} else {
#
# IMprove this with other error codes
#
		$self->{loadstate} = LOADCD_STATE_REQUEST_DB_OK ;
		$self->{loaderror} = LOADCD_ERROR_NODBRECORD ;
		$log->error("Basic Release Info - no release info found on freedb  code" . $http->code);
	}

	my $callback=$self->{loadsuccesscallback};
	&$callback($self->{loadclient},$self->{loadcallbackparams});

}



sub retrieveCDDBError
{
	my $http    = shift;
	my $self    = $http->params('self');
	my $client  = $http->params('myclient');
	my $error   = $http->error;

	$log->info("Error while contacting Freedb: $error");
	$log->debug("code=". $http->code);

	$self->{loadstate} = LOADCD_STATE_REQUEST_DB_ERROR ;
	$self->{loaderror} = LOADCD_ERROR_NODBFETCHFAIL ;

	my $callback=$self->{loadfailedcallback};
	&$callback($self->{loadclient},$self->{loadcallbackparams});

}



sub ReadCDTOCSuccessCallback
{	
	my $client = shift;
	my $self   = shift;

	$client->unblock();

	my $url = saveCDTOC($self->renderAsOPML());

	$log->debug("setmode success - now display MB/CDDB info");

	my %params = (
		modeName => 'LoadCDContents',
		url      => $url,
		title    => 'CDplayer',
	);

	Slim::Buttons::Common::pushMode($client, 'xmlbrowser', \%params);

	# we'll handle the push in a callback
	$client->modeParam('handledTransition',1)

}

# Fit a title into the available display, truncating if necessary
sub fitTitle {
	my ( $client, $title, $numItems ) = @_;
	
	# number of items in the list, to fit the (xx of xx) text properly
	$numItems ||= 2;
	my $num = '?' x length $numItems;
	
	my $max    = $client->displayWidth;
	my $length = $client->measureText( $title . " ($num of $num) ", 1 );
	
	return $title . ' {count}' if $length <= $max;
	
	while ( $length > $max ) {
		$title  = substr $title, 0, -1;
		$length = $client->measureText( $title . "... ($num of $num) ", 1 );
	}
	
	return $title . '... {count}';
}

sub renderAsOPML()
{
use XML::Simple;

	my $self   = shift;
	my $output = '<?xml version="1.0" encoding="UTF-8"?>
<opml version="1.0">
	<head title="' . Slim::Utils::Strings::string('PLUGIN_CDPLAYER_LOAD_CD') . '">
		<expansionState></expansionState>
	</head>
	<body>
';

	$log->debug('renderasOPML called');
$log->debug ("Prefs UseMusicbrainz = " . $prefs->get('usemusicbrainz'));

	if ($prefs->get('usemusicbrainz') ==1) {

		my $mbrec = $self->{mbbasicrelease} ;
		my $release = $mbrec->{'release-list'}->{'release'};

		if (! defined ($release ) ) {
			if ($self->{loaderror} == LOADCD_ERROR_NOCD) {
				$output .= "\n\t\t<outline  text=\"" . string('PLUGIN_CDPLAYER_NO_TRACKS_FOUND') . "\" />";
				$output .= "\n\t\t<outline  text=\"" . string('PLUGIN_CDPLAYER_NO_CD_LOADED')    . "\" />";
			} else {
#				$output .= "\n\t\t<outline  text=\"" . string('PLUGIN_CDPLAYER_NO_RELEASE_INFO') . "\" />";
			}

		} else {
			foreach my $releaseid (@$release) {
				$output .= sprintf "\n\t\t\t<outline text=\"%s\" url=\"%s\" parser=\"Plugins::CDplayer::CDPlayerParserMBAlbumrec\" type=\"playlist\" />", 
							URI::Escape::uri_escape($releaseid-> {'title'} . string('PLUGIN_CDPLAYER_BY') . $releaseid->{'artist'}->{'name'}),
#							$releaseid-> {'title'} . string('PLUGIN_CDPLAYER_BY') . $releaseid->{'artist'}->{'name'},
							HTML::Entities::encode_entities("http://musicbrainz.org/ws/1/release/" . $releaseid->{id} . "?type=xml&inc=tracks+artist+counts") ;
			}
  		}
	} elsif ($prefs->get('usemusicbrainz') ==0) {

		my $cddbrec = $self->{cddbrec} ;
		$log->debug("CDDB recd=\'$cddbrec\'");
# I think this pattern needs to be simplified as records only use / as a artist / album separator
		$cddbrec  =~ /(\d+)\s([^\s]+)\s([^\s]+)\s([^\/|\:|\-]+)\s[\/|\:|\-]\s?(.*)\s?/;

#		$log->debug("Code=$1 Genre=$2 Discid=$3 Artist=$4  Album=$5");
#	Code 200 = One record matching,,  210 multiple exact matches , 211 mulitple inexact matches.
#
		if ( $1 == 200 ) {
#		CODE =>1 GENRE=>$2,DISCID=>$3,ARTIST=>$4,ALBUM=>$5
# 200 soundtrack ee10bf12 Howard Shore / The Lord Of The Rings: The Fellowship Of The Ring
			$output .= sprintf "\n\t\t\t<outline text=\"%s\" url=\"%s\" parser=\"Plugins::CDplayer::CDPlayerParserCDDBAlbumrec\" type=\"playlist\" />", 
							HTML::Entities::encode_entities_numeric(decode("UTF8",($5 . string('PLUGIN_CDPLAYER_BY') . $4)))  ,

#							$5 . string('PLUGIN_CDPLAYER_BY') . $4  ,
							HTML::Entities::encode_entities("http://freedb.freedb.org/~cddb/cddb.cgi?cmd=cddb+read+". $2 . "+" . $3 . "&hello=anonymous+localhost+SqueezeCenter+CDplayer1.0&proto=6") ;
		} elsif ( ($1 == 210) || 
			( ($1 == 211) && ( $prefs->get('cddbinexact') == 1)) ) {

#  Exact (210) and Inexact (211) matched records have the following format
# genre discid  Album Artist / Album Title 
# data 370b1116 Various Artists / Kill Bill, Vol. 1
# misc 370b1116 OST / Kill Bill Vol. 1
# soundtrack 370b1116 Various Artists / Kill Bill Vol. 1 [Soundtrack]
			my @cddblines = split (/^/, $cddbrec);
			foreach my $line (@cddblines) {
#$log->debug("CDDBline: $line");
				$line =~ s/\n/ /g;  # change LF to space
				$line =~ s/\r//g;   # Get rid of CR if any.
				$line =~ s/\s+$//;  # get rid of trailing spaces;
				if ($line =~ m/^(\d+)\s/) { $log->debug("Found leading code $1");next;} ;  # Skip line starting with code;
				if ($line =~ m/^\./ )  { $log->debug("Found terminating dot"); last;}  ;
#					$log->debug("CDDBline2: $line");

				if ($line =~ m/([^\s]+)\s([^\s]+)\s([^\/|\:|\-]+)\s[\/|\:|\-]\s?(.*)\s?/) {
#					$log->debug("CDDBline: >$1<>$2<>$3<>$4< ");
					$output .= sprintf "\n\t\t\t<outline text=\"%s\" url=\"%s\" parser=\"Plugins::CDplayer::CDPlayerParserCDDBAlbumrec\" type=\"playlist\" />", 
						HTML::Entities::encode_entities_numeric(decode("UTF8",($4 . string('PLUGIN_CDPLAYER_BY') . $3 . ' ['. $1 .']' ))),
						HTML::Entities::encode_entities("http://freedb.freedb.org/~cddb/cddb.cgi?cmd=cddb+read+". $1 . "+" . $2 . "&hello=anonymous+localhost+SqueezeCenter+CDplayer1.0&proto=6") ;
				}
			}
		} else {
			if ($self->{loaderror} == LOADCD_ERROR_NOCD) {
				$output .= "\n\t\t<outline  text=\"" . string('PLUGIN_CDPLAYER_NO_TRACKS_FOUND') . "\" />";
				$output .= "\n\t\t<outline  text=\"" . string('PLUGIN_CDPLAYER_NO_CD_LOADED')    . "\" />";
			} else {
#				$output .= "\n\t\t<outline  text=\"" . string('PLUGIN_CDPLAYER_NO_RELEASE_INFO') . "\" />";
			}

		}
  	}

	
#
# Do Raw now
#
	if ( $self->{loaderror} != LOADCD_ERROR_NOCD) {

#
# If CD-Text is defined create a menu with CD-Text info
#
		if (defined($self->{albumtitle}) ) {
			$output .= "\n\t<outline text=\"" . URI::Escape::uri_escape( string('PLUGIN_CDPLAYER_CDTEXT') . $self->{albumtitle} . string('PLUGIN_CDPLAYER_BY') . $self->{albumartist}) . "\" type=\"playlist\" >";

			for ( my $tracknum = $self->{firstTrack}; $tracknum <= $self->{lastTrack}; $tracknum++)  {
				my $trackparams=
						'?AlbumTitle='  . URI::Escape::uri_escape_utf8($self->{albumtitle})                .
						'&AlbumArtist=' . URI::Escape::uri_escape_utf8($self->{albumartist})              .
						'&TrackTitle='  . URI::Escape::uri_escape_utf8($self->{tracktitles}[$tracknum])   .
						'&TrackArtist=' . URI::Escape::uri_escape_utf8($self->{trackartists}[$tracknum])  .
						'&Lengths='     . $self->{lengths}[$tracknum] .
						'&Offsets='     . $self->{offsets}[$tracknum] ;

				$output .= sprintf "\n\t\t\t<outline text=\"" . HTML::Entities::encode_entities_numeric(decode("UTF8",( $self->{tracktitles}[$tracknum] . string('PLUGIN_CDPLAYER_BY') . $self->{trackartists}[$tracknum] . ' ('. $self->{durations}[$tracknum] .')' ))) . "\" url=\"cdplay://%d%s\" type=\"audio\"/>",
						, $tracknum,HTML::Entities::encode_entities($trackparams) ;	
			}
  			$output .="\n\t</outline>";
		}

#
#  Dop the raw outpout
#

		$output .= "\n\t<outline text=\"" . string('PLUGIN_CDPLAYER_CD_RAW') . "\" type=\"playlist\">";

		for ( my $tracknum = $self->{firstTrack}; $tracknum <= $self->{lastTrack}; $tracknum++)  {
			my $trackparams='?Lengths='     . $self->{lengths}[$tracknum] .
					'&Offsets='     . $self->{offsets}[$tracknum] .
				        '&TrackTitle='  . URI::Escape::uri_escape_utf8(sprintf(string ('PLUGIN_CDPLAYER_CDTRACK_FORMAT'),$tracknum,  $self->{durations}[$tracknum]));
			$output .= sprintf "\n\t\t\t<outline text=\"" . string ('PLUGIN_CDPLAYER_CDTRACK_FORMAT') . "\" url=\"cdplay://%d%s\" type=\"audio\"/>",
					$tracknum,  $self->{durations}[$tracknum], $tracknum,HTML::Entities::encode_entities($trackparams) ;	
		}
   		$output .="\n\t</outline>";
  	}
   
  	$output .= "\n\t</body>\n</opml>\n";

  	return $output;
}


sub killOrphans
{
	my $self = shift;
	if ($osdetected eq 'win') {

		KillOrphanChildProcesses('cdda2wav.exe');
	}	
}


use constant MAX_CD_TRACKS => 99;

use Data::Dumper;
use Text::ParseWords;
sub parsetoc
{
	my $self = shift;
	my $toc = shift;


	my $lastoffset ;

	my @offsets    = ();
	my @lengths    = ();
	my @durations  = ();

	my $tocAlbumTitle;
	my $tocAlbumArtist;
	my @tocTrackTitle = ();
	my @tocTrackArtist= ();

	my $firstTrack = -1;
	my $lastTrack;


	@offsets[MAX_CD_TRACKS]   = 0;
	@lengths[MAX_CD_TRACKS]   = 0;
	@durations[MAX_CD_TRACKS] = 0;
	$lastoffset               = 0;

	my @cdinfo = split /^/, $toc;
	my $cdtextdetected;

	foreach my $line (@cdinfo) {
#	T01:       0  3:37.51 audio linear copydenied stereo title '' from ''
#	T02:   16326  3:08.30 audio linear copydenied stereo title '' from ''
#.
#.
#.
#	T22:  296697  5:47.57 audio linear copydenied stereo title '' from ''
#	Leadout:  322779

#
#      my @fields = m/\s* ( '(?:(?!(?<!\\)').)*' | +\S+)/gx;

#

		my @chunks = split " ",$line;
		my @parsewords = quotewords('\\s+', 0, $line);
#			$log->debug("ParseWord = ". Dumper(@parsewords));

#			$log->debug("Chunks = ". Dumper(@chunks));
#	$log->debug("Line: $line");;
		if (($chunks[0] eq 'CDINDEX') && ($chunks[1] eq 'discid:') ) {
			$log->debug("MusicBrainz DiscId is " . $chunks[2]);
		} 

		if (($chunks[0] eq 'CDDB') && ($chunks[1] eq 'discid:') ) {
			$log->debug("CDDB DiscId is " . $chunks[2]);
		} 
		if (($chunks[0] eq 'CD-Text:') && ($chunks[1] eq 'detected') ) {
			$log->debug("CD-Text detected on disc " );
			$cdtextdetected = 1;
		} 

		if (($chunks[0] eq 'Album') && ($chunks[1] eq 'title:') ) {
			if ($cdtextdetected) {
				$tocAlbumTitle  = $parsewords[2];
				$tocAlbumTitle  =~ s/\\'/'/g;
				$tocAlbumArtist = $parsewords[4];
				$tocAlbumArtist  =~ s/\\'/'/g;

				$log->debug("Album  Title=\"". $parsewords[2] . "\"  Artist =\"" . $parsewords[4] . "\"");				

			};

			
		}

		if (($chunks[0] =~ m/^\s*T(\d+):/) && ($chunks[3] eq 'audio')) {
			$firstTrack = int($1) if ($firstTrack==-1);
			$lastTrack = int($1);
			@lengths[$lastTrack-1] = $chunks[1] - $lastoffset;
			@offsets[$lastTrack] = $chunks[1] +150;
			@durations[$lastTrack] = $chunks[2];
			$lastoffset = $chunks[1];

			if ($cdtextdetected) {
				@tocTrackTitle[$lastTrack]  = $parsewords[8];
				@tocTrackTitle[$lastTrack]  =~ s/\\'/'/g;
				@tocTrackArtist[$lastTrack] = $parsewords[10];
				@tocTrackArtist[$lastTrack] =~ s/\\'/'/g;
				$log->debug("Track $lastTrack  Title=\"". $parsewords[8] . "\"  Artist =\"" . $parsewords[10] . "\"");				
			}
		}

		if ($chunks[3] eq 'data'){
			@lengths[$lastTrack]=  $chunks[1] - $lastoffset;
			@offsets[0] = $chunks[1] +150;
			last;
		}

		if ($chunks[0] eq 'Leadout:'){
			@lengths[$lastTrack]=  $chunks[1] - $lastoffset;
			@offsets[0] = $chunks[1] +150;
			last;
		}
	}

	$self->{offsets}   = [ @offsets ];
	$self->{lengths}   = [ @lengths ];
	$self->{durations} = [ @durations ];
	if ($cdtextdetected) {
		$self->{tracktitles}  = [@tocTrackTitle];
		$self->{trackartists} = [@tocTrackArtist];
		$self->{albumartist}  = $tocAlbumArtist;
		$self->{albumtitle}   = $tocAlbumTitle;
	} else {
		$self->{albumartist}  = undef;
		$self->{albumtitle}   = undef;
	}

	if ($firstTrack==-1) {
# No tracks were found... probably no CD in the drive
		$log->debug("ERROR: No tracks were found");
		$self->{loaderror} = LOADCD_ERROR_NOCD;
	} else {
		$self->{firstTrack} = $firstTrack;
		$self->{lastTrack}  = $lastTrack;
	}

  return;
}

sub computeMBDiscId
{

	my $self = shift;
	my $mbDiscId;

    # Compute the MusicBrainz DiscId
    # See http://wiki.musicbrainz.org/DiscIDCalculation
	my $ctx = Digest::SHA1->new;

  	$ctx->add(sprintf "%02X", $self->{firstTrack});
  	$ctx->add(sprintf "%02X", $self->{lastTrack});
  	foreach my $off (@{$self->{offsets}}) {

  		$ctx->add(sprintf "%08X", $off);
  	}

    # The DiscId is the SHA digest of the above info, converted into
    # base64. MB uses a slightly different base64 scheme than is
    # standard; using ._- instead of +/=. It also rounds up to four
    # characters, so requires an additional - at the end.
	my $sha=$ctx->b64digest;
	$sha =~ tr%+/=%._-%;

	my $mbDiscIdcalc = $sha . "-";
	$mbDiscId = $mbDiscIdcalc;

	$self->{mbDiscId}   = $mbDiscId;
	return $mbDiscId;	
	
}


#* 
#*  Note: Pearl Jam's album Vs. has N = 12 tracks. The first track
#*  starts at frames[0] =  150, the second at frames[1] = 14672,
#*  the twelfth at frames[11] = 185792, and the disc ends at
#*  frames[N] = 208500. Its disc id is 970ADA0C.
#*
#*  The disc id is a 32-bit integer, which we represent using 8
#*  hex digits XXYYYYZZ. 
#*
#*     - XX is the checksum. The checksum is computed as follows:
#*       for each starting frame[i], we convert it to seconds by
#*       dividing by the frame rate 75; then we sum up the decimal
#*       digits. E.g., if frame[i] = 7500600, this corresponds to
#*       100008 seconds whose digit sum is 1 + 8 = 9.
#*       XX is the total sum of all of these digit sums mod 255.
#*     - YYYY is the length of the album tracks in seconds. It is 
#*       computed as (frames[N] - frames[0]) / 75 and output in hex.
#*     - ZZ is the number of tracks N expressed in hex.
#*

# return sum of decimal digits in n

sub cddb_sum {
  my $n=shift;
  my $ret=0;

  while ($n > 0) {
    $ret += ($n % 10);
    $n = int $n / 10;
  }
  return $ret;
}

use constant FRAMES_PER_SECOND => 75;

sub computeCDDBDiscId 
{

	my $self = shift;
	my $frames = $self->{offsets};
	my $n = $self->{lastTrack} - $self->{firstTrack} + 1;
	my $querystr ="+$n";

	my $checkSum = 0;

	for (my $i = 1; $i <= $n; $i++) {
         $checkSum += cddb_sum(int($frames->[$i] / FRAMES_PER_SECOND));
         $querystr = $querystr . "+$frames->[$i]" ;

	}

	my $querystr = $querystr . "+" . int ($frames->[0] / FRAMES_PER_SECOND);
	my $xx    = $checkSum % 255;
	my $yyyy  = int ($frames->[0] / FRAMES_PER_SECOND) - int ($frames->[1] / FRAMES_PER_SECOND) ;
	my $zz    = $n;

#$log->debug(sprintf(" xx=%02x  yyyy=%04x  zz=%02x", $xx, $yyyy, $zz));
#      XXYYYYZZ
	my $discID =  sprintf ( "%08x", (($xx << 24) | ($yyyy << 8) | $n) );
	$log->info(" disc=$discID" );
 return ($discID, $querystr);
}

sub saveCDTOC
{
	my $feed = shift;
	my $fh;

	my $dir = $prefsServer->get('playlistdir');

	if (!$dir || !-w $dir) {
		$dir = $prefsServer->get('cachedir');
	}

	my $file = catdir($dir, "CDplayerCDTOC.opml");

	my $menuUrl = Slim::Utils::Misc::fileURLFromPath($file);

	$log->debug("creating infobrowser menu file: $file");
	open($fh, ">",$file);
	print $fh $feed;
	close($fh); 

	return $menuUrl;
}

sub CDplaying
{
	my $self= shift;
	$self->{cdplaying} = shift if @_;
	return $self->{cdplaying};
}

sub isCDplaying
{
	my $self= shift;
	return $self->{cdplaying};
}


sub isCDinUse
{
	my $self= shift;
	return $self->{cduse};
}


sub getErrorText
{
	my $self= shift;

	my $errortext	= ( $self->{loaderror} == LOADCD_ERROR_NODBRECORD)	? 'No MusicBrainz or CDDB record found'
			: ( $self->{loaderror} == LOADCD_ERROR_GOTDBRECORD)	? 'Got MusicBrainz or CDDB record'
			: ( $self->{loaderror} == LOADCD_ERROR_NONE)		? 'Idle '
			: ( $self->{loaderror} == LOADCD_ERROR_NOCD)		? 'No CD in drive'
			: ( $self->{loaderror} == LOADCD_ERROR_NODBFETCHFAIL)	? 'Error - failed to get response from either CDDB or MusicBrainz'
			: ( $self->{loaderror} == LOADCD_ERROR_BUSY)		? 'CD is being used by another user - try again soon'
			:						 	  "Unknown error code= " . $self->{loaderror} ;

return $errortext;

}

my %cdromstates = (
	0 =>   "CDS_NO_INFO",
	1 =>   "CDS_NO_DISC",
	2 =>   "CDS_TRAY_OPEN",
	3 =>   "CDS_DRIVE_NOT_READY",
	4 =>   "CDS_DISC_OK",
	100 => "CDS_AUDIO",
	101 => "CDS_DATA_1",
	102 => "CDS_DATA_2",
	103 => "CDS_XA_2_1",
	104 => "CDS_XA_2_2",
	105 => "CDS_MIXED"
	);
my %cdrommsgs = (
	0   => "PLUGIN_CDPLAYER_CDS_NO_INFO",
	1   => "PLUGIN_CDPLAYER_CDS_NO_DISC",
	2   => "PLUGIN_CDPLAYER_CDS_TRAY_OPEN",
	3   => "PLUGIN_CDPLAYER_CDS_DRIVE_NOT_READY",
	4   => "PLUGIN_CDPLAYER_CDS_DISC_OK",
	100 => "PLUGIN_CDPLAYER_CDS_AUDIO",
	101 => "PLUGIN_CDPLAYER_CDS_DATA_1",
	102 => "PLUGIN_CDPLAYER_CDS_DATA_2",
	103 => "PLUGIN_CDPLAYER_CDS_XA_2_1",
	104 => "PLUGIN_CDPLAYER_CDS_XA_2_2",
	105 => "PLUGIN_CDPLAYER_CDS_MIXED"
	);

#
# CDROM ioctl Function codes
#

use constant  CDROM_DRIVE_STATUS => 21286;
use constant  CDROM_DISC_STATUS  => 21287;
#
#  CDROM result codes.
#
use constant 	CDS_NO_INFO         => 0 ;
use constant 	CDS_NO_DISC         => 1 ;
use constant 	CDS_TRAY_OPEN       => 2 ;
use constant 	CDS_DRIVE_NOT_READY => 3 ;
use constant 	CDS_DISC_OK         => 4 ;
use constant 	CDS_AUDIO           => 100 ;
use constant 	CDS_DATA_1          => 101 ;
use constant 	CDS_DATA_2          => 102 ;
use constant 	CDS_XA_2_1          => 103 ;
use constant 	CDS_XA_2_2          => 104 ;
use constant 	CDS_MIXED           => 105 ;


sub cdromstatus
{
	my $cdromdevice = shift;
	my $filehandle;
	my $drivestatus;
	my $diskstatus;

#
# For non Unix systems - return success.
#
	if ($osdetected ne 'unix') {	
		return (1,undef,undef);
	}
	
#	if ( open ( $filehandle, "<" , $cdromdevice) ) {
	if ( sysopen ( $filehandle, $cdromdevice, O_RDONLY | O_NONBLOCK) ) {
		$log->debug("CDROM radio device $cdromdevice opened OK");
	} else {
		$log->error("Cannot open device: $cdromdevice error:$! (". int($!) . ")");
		return (0,-1,'PLUGIN_CDPLAYER_CANT_OPEN');
	}  

	$drivestatus = ioctl ( $filehandle , CDROM_DRIVE_STATUS , 0 ) || -1;
	if ($drivestatus < 0 ) {
		$log->error("CDROM Status: get cdrom device status ioctl failed ($drivestatus): $! (". int($!) . ")");
		return (-1, $drivestatus,'PLUGIN_CDPLAYER_FAILED_DRIVE_STATUS');
	}	
	$log->debug("cdrom drive status $drivestatus  text=". $cdromstates{$drivestatus} .  " errmsg=". $cdrommsgs{$drivestatus});

#
#  Check if drivestatus is CDS_DISC_OK - there is a readable disk in the drive
#
	if ($drivestatus != CDS_DISC_OK ) {
		close ($filehandle) ;
		return (0, $drivestatus,$cdrommsgs{$drivestatus});
	}

#
#  Check thast the disk is an audio disc or has audio content.
#

	$diskstatus = ioctl ( $filehandle , CDROM_DISC_STATUS , 0 ) ;
	$log->debug("cdrom disc status $diskstatus  code=". $cdromstates{$diskstatus} . " errmsg=". $cdrommsgs{$diskstatus});
	if ( ($diskstatus == CDS_MIXED) || ($diskstatus == CDS_AUDIO ) ) {
		close ($filehandle) ;
		return (1, $diskstatus,$cdrommsgs{$diskstatus});
	}

	return (0, $diskstatus,$cdrommsgs{$diskstatus});

}

sub KillOrphanChildProcesses( )
{

	my $orphanedExecutable = lc(shift) ;

	my	($pe32Size,$pe32Usage,$pe32ProcessID,$pe32DefaultHeapID,$pe32ModuleID,
		$pe32Threads,$pe32ParentProcessID,$pe32PriClassBase,$pe32Flags,$pe32ExeFile);
	my	$processentry32;
	my	$return;
	my	$handle;
	my	%processparent; 
	my	%alivepids;
	my	$exeparentpid;
	my	$exepid;

use constant TH32CS_SNAPPROCESS => 0x02;

		$handle = $createToolhelp32Snapshot->Call(TH32CS_SNAPPROCESS, 0 );
		$log->debug("Handle = $handle");
		$pe32Size = 296;

		$processentry32 = pack("LLLLLLLLLZ260",$pe32Size,$pe32Usage,$pe32ProcessID,$pe32DefaultHeapID,$pe32ModuleID,$pe32Threads,$pe32ParentProcessID,$pe32PriClassBase,$pe32Flags,$pe32ExeFile);
		$return = $process32First->Call($handle,$processentry32);
		if ($return != 1) {
			$log->error("process32First return =$return");
			return undef;
		}

	my $orphancount  = 0;
	my $processcount = 0;

		do { 
			($pe32Size,$pe32Usage,$pe32ProcessID,$pe32DefaultHeapID,$pe32ModuleID,
			$pe32Threads,$pe32ParentProcessID,$pe32PriClassBase,$pe32Flags,$pe32ExeFile) = unpack("LLLLLLLLLZ260",$processentry32);
			$alivepids{$pe32ProcessID} = 1;
#			$log->debug(sprintf("PID=%08x Parent Pid=%08x exe=%s",$pe32ProcessID,$pe32ParentProcessID,$pe32ExeFile));
			if (lc($pe32ExeFile) eq $orphanedExecutable) {
				$log->debug( "  Match Process ID =$pe32ProcessID  parent=$pe32ParentProcessID  target executable=$pe32ExeFile" );
				$processparent{$pe32ProcessID} = $pe32ParentProcessID;
				$orphancount++;
			} else {
#				$log->debug( "  No match Process ID =$pe32ProcessID ($pe32ExeFile)" );
			}
			$processcount++;
		} while ( ($return = $process32Next->Call($handle,$processentry32)));		

	$return = $closeHandle->Call($handle);

	$log->debug( " Found $orphancount possible orphan processes out of $processcount processes"  );
#	$log->debug("Dump processparent\n". Dumper(%processparent));

	foreach my $pid ( keys %processparent) {
		
		if ($alivepids{$processparent{$pid}}) {
			$log->debug( "Possible orphan $pid has alive parent pid ".$processparent{$pid});
		} else {
			$log->debug( "About to kill process $pid - whose parent pid ".$processparent{$pid});
			my $processobj;
			my $return = Win32::Process::Open($processobj,$pid,0);
			if ($return == 0) {
				$log->error("Failed to open process $pid");
			} else {
				$processobj->Kill(0);
			}
		}
	}
 return;
}










1;
