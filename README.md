CastleDB
========
<a href="http://castledb.org"><img src="http://castledb.org/img/icon_hd.png" align=right /></a>

_A structured database and level editor with a local web app to edit it._

### Why
CastleDB is used to input structured static data. Everything that is usually stored in XML or JSON files can be stored and modified with CastleDB instead. For instance, when you are making a game, you can have all of your items and monsters including their names, description, logic effects, etc. stored in CastleDB.

###  How
<img src="http://castledb.org/img/screen.png"  width=50% align=right  />
CastleDB looks like any spreadsheet editor, except that each sheet has a data model. The model allows the editor to validate data and eases user input. For example, when a given column references another sheet row, you will be able to select it directly.


###  Storage
CastleDB stores both its data model and the data contained in the rows into an easily readable JSON file. It can then easily be loaded and used by any program. It makes the handling of item and monster data that you are using in you video game much easier.

###  Collaboration
<img src="http://castledb.org/img/levelEdit.png" width=50% align=right />
CastleDB allows efficient collaboration on data editing. It uses the JSON format with newlines to store its data, which in turn allows RCS such as GIT or SVN to diff/merge the data files. Unlike online spreadsheet editors, changes are made locally. This allows local experiments before either commiting or reverting.


### Download

##### Windows x64
http://castledb.org/file/castledb-1.5-win.zip
##### OSX x64
http://castledb.org/file/castledb-1.5-osx.zip
##### NodeJS Package
https://nodejs.org/en/


### Compile from sources:

#### 1. Install Prerequisites
- Install [Haxe](https://haxe.org) using approriate installer from https://haxe.org/download/
- Install dependencies (https://github.com/HaxeFoundation/hxnodejs) using the command `haxelib install castle.hxml`

#### 2. Build castle.js
- Clone this repository
- At the root of the repository folder run
```haxe castle.hxml```
- This will create `castle.js` file in the `bin` folder

#### 3. Package or Run with NWJS
- cd bin/
- npm install  (at first launch)
- npm run start (to run castledb app)

### More info
Website / documentation: http://castledb.org
