# CD Player Plugin for SqueezeCenter

# Copyright (C) 2008 Bryan Alton and others
# All rights reserved.

# This program is free software; you can redistribute it and/or
# modify it under the same terms as Perl itself.

package Plugins::CDplayer::CDPlayerParserCDDBAlbumrec;

use strict;

use Slim::Utils::Log;
use XML::Simple;
use Data::Dumper;
use Slim::Utils::Misc;
use Slim::Utils::Strings qw(string);

use HTML::Entities;
use URI::Escape;

use Encode;

my $log    = logger('plugin.cdplayer');
my $cdInfo = Plugins::CDplayer::Plugin::cdInfo(); 

sub parse
{

	my $class  = shift;
	my $http   = shift;

	my $params = $http->params('params');
	my $url    = $params->{'url'};
	my @items = ();
	my @content = split /^/, $http->content;
	my $albumartist;
	my $albumtitle;
	my $albumgenre;
	my $albumyear;
	my $albumdiscid;
	my $trackartist;
	my $tracktitle;

	my @tracktitles;
	
	LOOP:
	foreach my $line (@content) {

		$line =~ s/\n/ /g;  # change LF to space
		$line =~ s/\r//g;   # Get rid of CR if any.
		$line =~ s/\s+$//;  # Strip trailing blanks

		if ( $line =~ m/^#/ ) {
		 	next LOOP;
		};

		if ( $line =~ m/^\./ ) {
			last LOOP;
		};
		my ($datatype,$datavalue) = split (/=/ , $line);
		if ($datatype eq 'DISCID') {
			$albumdiscid = $datavalue;
			next LOOP;
		}

		if ($datatype eq 'DTITLE') {
			$albumtitle .=$datavalue;
			next LOOP;
		}

		if ($datatype eq 'DGENRE') {
			$albumgenre = $datavalue;
			next LOOP;
		}

		if ($datatype =~ m/^TTITLE(\d+)/) {
			my $tracknum = $1 + 1;
			$tracktitles[$tracknum] .= $datavalue;
		}
	}

# CDDB spec says "/" should have space either side - this is not the case in reality.
#	if ( $albumtitle =~ m/([^\/]+)\s[\/]\s?(.*)\s?/) {
	if ( $albumtitle =~ m/([^\/]+)[\/](.*)\s?/) {
		$albumtitle = $2;
		$albumartist = $1;
	};

	for (my $j=0; $j <=$#tracktitles; $j++) {
		my $temptracktitle;
		if (defined($tracktitles[$j])) {
			$log->debug("opml entry: Track $j Title \'$tracktitles[$j]\'");

# CDDB spec says "/" should have space either side - this is not the case in reality.
			if ( $tracktitles[$j] =~ m/([^\/]+)[\/](.*)\s?/) {
				$log->debug("TrackArtist=$1  TrackTitle=$2");
				$tracktitle = $2;
				$trackartist = $1;
				$temptracktitle = $tracktitle . Slim::Utils::Strings::string('PLUGIN_CDPLAYER_BY') . $trackartist ;
			} else {
				$trackartist = undef;
				$tracktitle     = $tracktitles[$j];
				$temptracktitle = $tracktitles[$j];
			}
	
			my $trackparams='?CDDBDiscid='    . $albumdiscid .
				'&AlbumTitle='  . URI::Escape::uri_escape($albumtitle)  .
				'&AlbumArtist=' . URI::Escape::uri_escape($albumartist) .
				'&TrackTitle='  . URI::Escape::uri_escape($tracktitle)  .
				'&TrackArtist=' . URI::Escape::uri_escape($trackartist) .
				'&Lengths='     . $cdInfo->{lengths}[$j] .
				'&Offsets='     . $cdInfo->{offsets}[$j] ;

			my $trackname = sprintf "%02d. %s (%s)", 
				$j, decode("UTF8",$temptracktitle)  , $cdInfo->{durations}[$j] ;
			push @items, (
				{
				name 	=> $trackname ,
				url  	=> "cdplay://$j$trackparams",
				type	=> 'audio',
				}
			);
		}
	}

	return {
		'type'  => 'opml',
		'title' => decode("UTF8","CD: $albumtitle" . Slim::Utils::Strings::string('PLUGIN_CDPLAYER_BY') . "$albumartist"),
		'items' => [@items],
		'nocache' => 1,
	};

}

1;
