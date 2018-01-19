<?php

/**
 * @author     Garda Informatica <info@gardainformatica.it>
 * @copyright  Copyright (C) 2014 Garda Informatica. All rights reserved.
 * @license    http://www.gnu.org/licenses/gpl-3.0.html  GNU General Public License version 3
 * @package    JSocialFeed Joomla Extension
 * @link       http://www.gardainformatica.it
 */

/*

This file is part of "JSocialFeed Joomla Extension".

"JSocialFeed Joomla Extension" is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version.

"JSocialFeed Joomla Extension" is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with "JSocialFeed Joomla Extension".  If not, see <http://www.gnu.org/licenses/>.

*/

defined('_JEXEC') or die;

$document = JFactory::getDocument();

$custom_css=$params->get('custom_css','');
if (!empty($custom_css)){
	$document->addStyleDeclaration($custom_css);
}

?>

<div id="jsocialfeed-loading-module-<?php echo $module->id;?>" class="bx-wrapper" style="max-width: 100%; margin: 0px auto;">
	<div class="bx-viewport jsocialfeed_loading" style="width: 100%; overflow: hidden; position: relative; height: 5px;">
	<noscript><?php echo JText::_("JSOCIALFEED_JAVASCRIPT_REQUIRED"); ?></noscript>
	</div>
</div>
<ul id="jsocialfeed-module-<?php echo $module->id;?>" class="jsocialfeed<?php echo $moduleclass_sfx; ?>" >
</ul>
