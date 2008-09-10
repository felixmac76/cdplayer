# CD Player Plugin for SqueezeCenter

# Copyright (C) 2008 Bryan Alton and others
# All rights reserved.

# This program is free software; you can redistribute it and/or
# modify it under the same terms as Perl itself.

package Plugins::CDplayer::Plugin;

use strict;

use base qw(Slim::Plugin::Base);

use Slim::Utils::Prefs;
use Slim::Utils::Log;
use Slim::Utils::Misc;
use Slim::Utils::Strings qw(string);
use Slim::Utils::OSDetect;
use File::Spec::Functions qw(:ALL);
use Plugins::CDplayer::Settings;
use Plugins::CDplayer::CDhandler;
use Data::Dumper;

# create log categogy before loading other modules
my $log = Slim::Utils::Log->addLogCategory( {
	category     => 'plugin.cdplayer',
	defaultLevel => 'ERROR',
	description  => getDisplayName(),
} );


my $prefsServer = preferences('server');
my $prefs       = preferences('plugin.cdplayer');

use Plugins::CDplayer::CDPLAY;

my $cdInfo;  # Store the potiner to CDInfo object whichs describes the state of CD drive

################################
### Plugin Interface ###########
################################


# Get toc
# cdda2wav -device $device -verbose-level=toc -N -g -J
#
# Rip a track
# cdda2wav  -device $device -no-infofile -track $tracknum 
#

sub initPlugin() 
{
	my $class = shift;
	my $device;
	$log->info("Initialising CDPlayer" . $class->_pluginDataFor('version'));


	Plugins::CDplayer::Settings->new($class);
	Plugins::CDplayer::Settings->init();


	$cdInfo = Plugins::CDplayer::CDhandler->new( );
	$cdInfo->init();

	if (!$class->_pluginDataFor('icon')) {

		Slim::Web::Pages->addPageLinks("icons", { $class->getDisplayName => 'html/images/icon.png' });
	}

	$class->SUPER::initPlugin();

	Slim::Buttons::Common::addMode('PLUGIN.CDplayer', getFunctions(), \&setMode);

#        |requires Client
#        |  |is a Query
#        |  |  |has Tags
#        |  |  |  |Function to call
#        C  Q  T  F
	Slim::Control::Request::addDispatch(['cdplayer', 'items', '_index', '_quantity'],
        [0, 1, 1, \&cliQuery]);
	Slim::Control::Request::addDispatch(['cdplayer', 'playlist', '_method' ],
	[1, 1, 1, \&cliQuery]);

	my @item = ({
			text           => Slim::Utils::Strings::string(getDisplayName()),
			weight         => 20,
			id             => 'cdplayer',
			node           => 'extras',
			'icon-id'      => $class->_pluginDataFor('icon'),
			displayWhenOff => 0,
			window         => { titleStyle => 'album' },
			actions => {
				go =>      {
					'cmd' => ['cdplayer', 'items'],
					'params' => {
						'menu' => 'cdplayer',
					},
				},
			},
		});

	Slim::Control::Jive::registerPluginMenu(\@item);

	Slim::Control::Request::subscribe( \&pauseCallback, [['pause']] );

}

sub shutdownPlugin 
{
	my $class = shift;

	# unsubscribe
	Slim::Control::Request::unsubscribe(\&pauseCallback);

	$log->info("Plugin shutdown - kill any cdda2wav processes left behind");
	$cdInfo->killOrphans();

	return;
}

sub getFunctions {
	return {};
}


sub getDisplayName() 
{ 
	return('PLUGIN_CDPLAYER')
}

sub cdInfo()
{
	my $class = shift;

	return $cdInfo ;
}


sub setMode {
	my $class =  shift;
	my $client = shift;
	my $method = shift;

	if ($method eq 'pop') {
		Slim::Buttons::Common::popMode($client);
		return;
	}

	if( $cdInfo->isCDplaying() ) {
		my $url =  Plugins::CDplayer::CDhandler::saveCDTOC($cdInfo->renderAsOPML());

		my %params = (
			modeName => 'LoadCDContents',
			url      => $url,
			title    => 'CDplayer pushmode',
		);

		Slim::Buttons::Common::pushMode($client, 'xmlbrowser', \%params);

#	Not exactly sure abouth what the follwing does but it is in OPMLbased.pm
#	we'll handle the push in a callback
		$client->modeParam('handledTransition',1)
	}
	else {
		Slim::Buttons::Common::pushMode($client, 'loadcd');
	}
}

sub webPages {
	my $class = shift;

	my $title = getDisplayName();
	my $url   = 'plugins/CDplayer/index.html';

# Add CDplayer menu item under Extras
	Slim::Web::Pages->addPageLinks('plugins', { $title => $url });
	
#	Slim::Web::HTTP::protectURI($url);
	Slim::Web::HTTP::addPageFunction($url, \&indexHandler );
}

sub indexHandler
{
	my ( $client, $stash, $callback, $httpClient, $response ) = @_;
	$log->info("CDplayer - Indexhandler called");

	if ($cdInfo->isCDinUse() ) {
		$log->info("CD drive is currently loading a TOC for another client ");
		$stash->{'errormsg'} = sprintf(string('PLUGIN_CDPLAYER_WEB_ERROR'), -1 , 
					string('PLUGIN_CDPLAYER_CD_BUSY') . ' '. string('PLUGIN_CDPLAYER_TRY_AGAIN'));
 
		my $output = Slim::Web::HTTP::filltemplatefile('plugins/CDplayer/index.html', $stash);
		&$callback($client, $stash, $output,  $httpClient, $response);
	} else {
		if( $cdInfo->isCDplaying() ) {
			ReadCDTOCSuccessWebCallback($client,\@_);
		} else { 
			$cdInfo->LoadCDandIdentify($client, \&ReadCDTOCSuccessWebCallback, \&ReadCDTOCFailedWebCallback, \@_);
		}
	}
	return 0;
}


sub ReadCDTOCSuccessWebCallback
{
	my $client = shift;
	my ( $clientparam, $stash, $callback, $httpClient, $response ) = @_;

	my $title = getDisplayName();
	$log->debug('Read MusicBrainz record OK - web callback');

	# Get OPML list of feeds from cache
	my $url = Plugins::CDplayer::CDhandler::saveCDTOC($cdInfo->renderAsOPML());
	Slim::Web::XMLBrowser->handleWebIndex( {
		client => $client,
		feed   => $url,
		title  => $title,
		args   => ($clientparam, $stash, $callback, $httpClient, $response)
	} );
}

sub ReadCDTOCFailedWebCallback
{
	my $client = shift;
	my $params = shift;

	my ( $clientparam, $stash, $callback, $httpClient, $response ) = @$params;

	$log->debug('Read MusicBrainz record failed - web callback');

	$stash->{'errormsg'} = sprintf(string('PLUGIN_CDPLAYER_WEB_ERROR'), $cdInfo->{loaderror} , $cdInfo->getErrorText() );
	my $output = Slim::Web::HTTP::filltemplatefile('plugins/CDplayer/index.html', $stash);
	&$callback($clientparam, $stash, $output,  $httpClient, $response);
}

sub cliQuery {
	my $request = shift;
	my $client = $request->client;

	$log->info("CDplayer - cliQuery called");

	$request->setStatusProcessing();	

	if (defined( $request->getParam('item_id')) || $cdInfo->isCDplaying()  ) {
		ReadCDTOCSuccessCLICallback($client, $request );
	} else {
		if ($cdInfo->isCDinUse() ) {
			$log->info("CD drive is currently loading a TOC for another client ");
			$request->addResult("networkerror", Slim::Utils::Strings::string('PLUGIN_CDPLAYER_CD_BUSY') . "  ". 
							Slim::Utils::Strings::string('PLUGIN_CDPLAYER_TRY_AGAIN'));
			$request->addResult('count', 0);
			$request->setStatusDone();
			return;
		}

		$cdInfo->LoadCDandIdentify($client, \&ReadCDTOCSuccessCLICallback, \&ReadCDTOCFailedCLICallback, $request);
	};
	# show feedback if this action came from jive cometd session
	if ($request->source && $request->source =~ /\/slim\/request/) {
		if (!defined( $request->getParam('item_id')) ) {
			$client->showBriefly({
				'jive' => { 
				'text'    => [ Slim::Utils::Strings::string('PLUGIN_CDPLAYER_LOADING_CD_WAIT'),
					   ],
				}
			});
		}
	}


}	

sub ReadCDTOCSuccessCLICallback
{
	my $client = shift;
	my $request = shift;
	# Get OPML list of Album
	my $url = Plugins::CDplayer::CDhandler::saveCDTOC($cdInfo->renderAsOPML());

	$log->info("CDplayer - executing XMLbrowser cliQuery with MB results");

	Slim::Buttons::XMLBrowser::cliQuery('cdplayer', $url, $request);
}

sub ReadCDTOCFailedCLICallback
{
	my $client = shift;
	my $request = shift;


	$request->addResult("networkerror", string('PLUGIN_CDPLAYER_CLI_ERROR') . $cdInfo->getErrorText());
	$request->addResult('count', 0);

	$request->setStatusDone();
}


sub pauseCallback {
	my $request = shift;
	my $client  = $request->client;

	my $stream  = Slim::Player::Playlist::song($client)->path;
	my $playmode= Slim::Player::Source::playmode($client);
	my $mode    = Slim::Buttons::Common::mode($client);

	$log->debug("cli Pause - playmode=$playmode  stream=$stream ");

	if ($stream =~ /^cdplay:/ ) {
#	if ($playmode eq 'pause' && $stream =~ /^cdplay:/ ) {
		if ($prefs->get('pausestop')) {
			$log->debug("Issuing stop");
			$client->execute([ 'stop' ]);
		}
	}

}


1;

# Local Variables:
# tab-width:4
# indent-tabs-mode:t
# End:
