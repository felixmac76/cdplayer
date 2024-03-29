# CD Player Plugin for SqueezeCenter

# Copyright (C) 2008 Bryan Alton and others
# All rights reserved.

# This program is free software; you can redistribute it and/or
# modify it under the same terms as Perl itself.

package Plugins::CDplayer::CDPLAY;

use strict;

use base qw(Slim::Player::Pipeline);
#use utf8;

use Slim::Utils::Strings qw(string);
use Slim::Utils::Misc;
use Slim::Utils::Log;
use Slim::Utils::Prefs;
use URI::Escape;
use HTML::Entities;

use Data::Dumper;

my $log   = logger('plugin.cdplayer');
my $prefs = preferences('plugin.cdplayer');
my $osdetected = Slim::Utils::OSDetect::OS();

use constant CDPLAYING => 1;
use constant CDSTOPPED => 0;


Slim::Player::ProtocolHandlers->registerHandler('cdplay', __PACKAGE__);

sub isRemote { 1 }

sub new {
	my $class = shift;
	my $args  = shift;
	my $cdInfo = Plugins::CDplayer::Plugin::cdInfo();
	my $cddevice; 
	if ($osdetected eq 'win') { # Use drop downlist built at startup
		$cddevice = $prefs->get('cddevice');
	} elsif ($osdetected eq 'unix') { # use text box
		$cddevice = $prefs->get('device');
	} else { # use drop down box filled with predefined OSX devcies name for CD/DVD drive.
		$cddevice = $prefs->get('cddevice');
	}

	$log->debug(" Host OS = $osdetected  CD device name=\'$cddevice\'");
	my $client  = $args->{'client'};
	my $fullurl = $args->{'url'} ;
	my ($baseurl,$params) = split (/\?/,$fullurl); 
	$baseurl =~ m|^cdplay://(\d+)|;	
	my $tracknum = $1;

	my $restoredurl;

	$log->debug("params length =". length ($params) ."\n" . Data::Dumper::Dumper($params));

	my %ops = map {
			my ( $k, $v ) = split( '=' );
#			$k  => Slim::Utils::Unicode::utf8decode_locale(uri_unescape( $v ))
			$k  => Encode::decode_utf8(uri_unescape( $v ))
		} split( '&', $params );

	Slim::Music::Info::setContentType($fullurl, 'cdplay');
	my ($command, $type, $format) = Slim::Player::TranscodingHelper::getConvertCommand($client, $fullurl);

	unless (defined($command) && $command ne '-') {
		$log->warn("Couldn't find conversion command for $fullurl");
		Slim::Player::Source::errorOpening($client, string('PLUGIN_CDPLAYER_NO_CONVERT_CMD'));
		return undef;
	}

	$log->debug("Full URL= $fullurl Format=$format");

	Slim::Music::Info::setContentType($fullurl, $format);

	my $maxRate = 0;
	my $quality = 1;

	if (defined($client)) {
		$maxRate = Slim::Utils::Prefs::maxRate($client);
		$quality = preferences('server')->client($client)->get('lameQuality');
	}

	$restoredurl = $baseurl;
	my $cdspeed = 4;
	$command =~ s/\$CDTRACK\$/$tracknum/;
	$command =~ s/\$CDDEVICE\$/$cddevice/;
	$command =~ s/\$CDSPEED\$/$cdspeed/;

	$command = Slim::Player::TranscodingHelper::tokenizeConvertCommand($command, $type, $restoredurl, $baseurl, 0, $maxRate, 1, $quality);
$log->debug("about to execute:$command");

#	if ($osdetected eq 'win') {
#		$command =~ s|\"cdplay://(\d+)\"| device=$cddevice -track $1|;

#	} elsif ($osdetected eq 'mac') {
#		$command =~ s|\"cdplay://(\d+)\"|  device=$cddevice -track $1|;

#	} else {
#		$command =~ s|\"cdplay://(\d+)\"|  device=$cddevice -track $1|;
#	}

	$cdInfo->{PlayingAlbumTitle}   =  $ops{AlbumTitle}    || Slim::Utils::Strings::string('PLUGIN_CDPLAYER_UNKNOWN_ALBUM'); 
	$cdInfo->{PlayingAlbumArtist}  =  $ops{AlbumArtist}   || Slim::Utils::Strings::string('PLUGIN_CDPLAYER_UNKNOWN_ARTIST') ;
	$cdInfo->{PlayingTrackTitle}   =  $ops{TrackTitle}    || Slim::Utils::Strings::string('PLUGIN_CDPLAYER_UNKNOWN_TRACK') ;
	$cdInfo->{PlayingTrackArtist}  =  $ops{TrackArtist} ;
	$cdInfo->{PlayingLengths}      =  $ops{Lengths} ;
	$cdInfo->{PlayingOffsets}      =  $ops{Offsets} ;
	$cdInfo->{PlayingMBDiscid}     =  $ops{MBDiscid};


	$log->info("SetCurrentTitle for $fullurl ");
	Slim::Music::Info::setCurrentTitle( $fullurl, $cdInfo->{PlayingTrackTitle} . ' (' . $cdInfo->{durations}[$tracknum] .')' );
	Slim::Music::Info::setDuration( $fullurl, (int($cdInfo->{PlayingLengths})/75) );

	$cdInfo->CDplaying ( CDPLAYING );

	my $self = $class->SUPER::new(undef, $command,'local');

	${*$self}{'contentType'} = $format;

	return $self;
}

sub contentType 
{
	my $self = shift;
	return ${*$self}{'contentType'};
}

sub isAudioURL { 1 }

sub OnCommandCDInfoCallback()
{
	my $client = shift;

	my $foundDiscId = shift;
	my $callback = $client->pluginData( 'onCommandCallback' );

	$log->debug("OnCommandCallback callback=$callback");
	return $callback->();
}

sub close 
{
	my $class = shift;
	$log->debug("closing cdda2wav stream to SC ");
	my $cdInfo = Plugins::CDplayer::Plugin::cdInfo();

	my $self = $class->SUPER::close();
	$cdInfo->CDplaying ( CDSTOPPED );

	$cdInfo->killOrphans();

}

# Metadata for a URL, used by CLI/JSON clients
sub getMetadataFor {
	my ( $class, $client, $url, $forceCurrent ) = @_;

	my $cdInfo = Plugins::CDplayer::Plugin::cdInfo();
	my $icon =   Plugins::CDplayer::Plugin->_pluginDataFor('icon');

	return {
		artist   =>  $cdInfo->{PlayingTrackArtist}  || $cdInfo->{PlayingAlbumArtist} ,
		album    =>  $cdInfo->{PlayingAlbumTitle} ,
		title    =>  $cdInfo->{PlayingTrackTitle}, 
		duration =>  int($cdInfo->{PlayingLengths})/75,
		type     =>  'CD',
		icon     =>  $icon ,
		cover    =>  $icon,
	};
}

# XXX - I think that we scan the track twice, once from the playlist and then again when playing
sub scanUrl {
	my ( $class, $url, $args ) = @_;
	
	Slim::Utils::Scanner::Remote->scanURL($url, $args);

}
1;

# Local Variables:
# tab-width:4
# indent-tabs-mode:t
# End:
