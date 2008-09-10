# CD Player Plugin for SqueezeCenter

# Copyright (C) 2008 Bryan Alton and others
# All rights reserved.

# This program is free software; you can redistribute it and/or
# modify it under the same terms as Perl itself.

package Plugins::CDplayer::CDPlayerParserAlbumrec;

use strict;

use Slim::Utils::Log;
use XML::Simple;
use Data::Dumper;
use Slim::Utils::Misc;
use HTML::Entities;
use URI::Escape;

my $log = logger('plugin.cdplayer');
my $cdInfo =Plugins::CDplayer::Plugin::cdInfo(); 

sub parse
{
	my $class  = shift;
	my $http   = shift;

	my $params = $http->params('params');
	my $url    = $params->{'url'};

	my @items = ();
	my $cdInfo = Plugins::CDplayer::Plugin::cdInfo();
	my $mbrec = XMLin( ${$http->{contentRef}} , 'forcearray' => [qw(track)], 'keyattr' => []);
	my $tracks = $mbrec->{'release'}->{'track-list'}->{'track'};
	my $tracknum = int($cdInfo->{firstTrack});
	
	foreach my $track  (@$tracks) {

		my $trackparams='?MBDiscid='    . $cdInfo->{mbDiscId} . 
				'&AlbumTitle='  . URI::Escape::uri_escape_utf8($mbrec->{'release'}->{'title'})            .
				'&AlbumArtist=' . URI::Escape::uri_escape_utf8($mbrec->{'release'}->{'artist'}->{'name'}) .
				'&TrackTitle='  . URI::Escape::uri_escape_utf8($track->{'title'})                         .
				'&TrackArtist=' . URI::Escape::uri_escape_utf8($track->{'artist'}->{'name'})              .
				'&Lengths='     . $cdInfo->{lengths}[$tracknum]                         .
				'&Offsets='     . $cdInfo->{offsets}[$tracknum] ;

		my $trackname = sprintf "%02d. %s (%s)", 
				$tracknum, URI::Escape::uri_unescape( $track->{'title'} ) , $cdInfo->{durations}[$tracknum] ;
		push @items, (
			{
			name 	=> $trackname ,
			url  	=> "cdplay://$tracknum$trackparams",
			type	=> 'audio',
			}
		);
		$tracknum = $tracknum + 1 ;
	}

	return {
		'type'  => 'opml',
		'title' => 'CD: ' .  $mbrec->{'release'}->{'title'} . ' by '. $mbrec->{'release'}->{'artist'}->{'name'} ,
		'items' => [@items],
#		'nocache' => 1,
	};

}

1;
