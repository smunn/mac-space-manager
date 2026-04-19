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

#endif
