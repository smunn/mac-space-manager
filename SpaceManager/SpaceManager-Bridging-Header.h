//
//  SpaceManager-Bridging-Header.h
//  SpaceManager
//
//  Core Graphics private API declarations for macOS Spaces detection.
//  Originally from Spaceman by Sasindu Jayasinghe (MIT License).
//

#ifndef SpaceManager_Bridging_Header_h
#define SpaceManager_Bridging_Header_h

#import <Foundation/Foundation.h>

int _CGSDefaultConnection(void);
CFArrayRef CGSCopyManagedDisplaySpaces(int conn);
id CGSCopyActiveMenuBarDisplayIdentifier(int conn);

// Maps window IDs to the space(s) they belong to.
// type is a bitmask: 1=current, 2=other, 0x7=all spaces.
// Returns CFArray of space IDs (CFNumbers) for the given windows.
CFArrayRef CGSCopySpacesForWindows(int conn, int type, CFArrayRef windowIDs);


#endif
