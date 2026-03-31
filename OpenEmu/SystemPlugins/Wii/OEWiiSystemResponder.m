/*
 Copyright (c) 2025, OpenEmu Team

 Redistribution and use in source and binary forms, with or without
 modification, are permitted provided that the following conditions are met:
     * Redistributions of source code must retain the above copyright
       notice, this list of conditions and the following disclaimer.
     * Redistributions in binary form must reproduce the above copyright
       notice, this list of conditions and the following disclaimer in the
       documentation and/or other materials provided with the distribution.
     * Neither the name of the OpenEmu Team nor the
       names of its contributors may be used to endorse or promote products
       derived from this software without specific prior written permission.

 THIS SOFTWARE IS PROVIDED BY OpenEmu Team ''AS IS'' AND ANY
 EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
 WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
 DISCLAIMED. IN NO EVENT SHALL OpenEmu Team BE LIABLE FOR ANY
 DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
 (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
  LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
 ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
  SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

#import "OEWiiSystemResponder.h"
#import "OEWiiSystemResponderClient.h"

@implementation OEWiiSystemResponder
@dynamic client;

+ (Protocol *)gameSystemResponderClientProtocol;
{
    return @protocol(OEWiiSystemResponderClient);
}

- (void)changeAnalogEmulatorKey:(OESystemKey *)aKey value:(CGFloat)value
{
    [self.client didMoveWiiJoystickDirection:(OEWiiButton)aKey.key withValue:value forPlayer:aKey.player];
}

- (void)pressEmulatorKey:(OESystemKey *)aKey
{
    [self.client didPushWiiButton:(OEWiiButton)aKey.key forPlayer:aKey.player];
}

- (void)releaseEmulatorKey:(OESystemKey *)aKey
{
    [self.client didReleaseWiiButton:(OEWiiButton)aKey.key forPlayer:aKey.player];
}

#pragma mark - Mouse IR Pointer

- (void)mouseMovedAtPoint:(OEIntPoint)aPoint
{
    // Convert game screen pixel coordinates to normalized IR range.
    // The aspectSize for Wii is 16:9 (854x480 effective), but the
    // actual buffer is 640x480. locationInGameView returns coordinates
    // scaled to the aspect-corrected screen size.
    // Dolphin's IR override expects -1.0..1.0 for both axes.
    // We approximate by assuming the game view coordinates map linearly.
    // X: 0 = far left (-1.0), screenWidth = far right (1.0)
    // Y: 0 = top (-1.0), screenHeight = bottom (1.0) — but Dolphin's
    //    Y axis is inverted (positive = up), so negate.

    // Use the 640x480 buffer dimensions as the reference frame since
    // locationInGameView scales to the aspect-corrected size.
    CGFloat screenWidth = 640.0;
    CGFloat screenHeight = 480.0;

    CGFloat normalizedX = ((CGFloat)aPoint.x / screenWidth) * 2.0 - 1.0;
    CGFloat normalizedY = -(((CGFloat)aPoint.y / screenHeight) * 2.0 - 1.0);

    // Clamp to valid range
    normalizedX = fmax(-1.0, fmin(1.0, normalizedX));
    normalizedY = fmax(-1.0, fmin(1.0, normalizedY));

    // Send as IR pointer movement for player 1
    // Positive X = right, positive Y = up in Dolphin's coordinate system
    if (normalizedX >= 0) {
        [self.client didMoveWiiJoystickDirection:OEWiiIRRight withValue:normalizedX forPlayer:1];
        [self.client didMoveWiiJoystickDirection:OEWiiIRLeft withValue:0.0 forPlayer:1];
    } else {
        [self.client didMoveWiiJoystickDirection:OEWiiIRLeft withValue:-normalizedX forPlayer:1];
        [self.client didMoveWiiJoystickDirection:OEWiiIRRight withValue:0.0 forPlayer:1];
    }

    if (normalizedY >= 0) {
        [self.client didMoveWiiJoystickDirection:OEWiiIRUp withValue:normalizedY forPlayer:1];
        [self.client didMoveWiiJoystickDirection:OEWiiIRDown withValue:0.0 forPlayer:1];
    } else {
        [self.client didMoveWiiJoystickDirection:OEWiiIRDown withValue:-normalizedY forPlayer:1];
        [self.client didMoveWiiJoystickDirection:OEWiiIRUp withValue:0.0 forPlayer:1];
    }
}

- (void)mouseDownAtPoint:(OEIntPoint)aPoint
{
    // Mouse click acts as Wiimote B button (trigger) for player 1
    [self.client didPushWiiButton:OEWiiButtonB forPlayer:1];

    // Also update IR position on click
    [self mouseMovedAtPoint:aPoint];
}

- (void)mouseUpAtPoint
{
    [self.client didReleaseWiiButton:OEWiiButtonB forPlayer:1];
}

- (void)rightMouseDownAtPoint:(OEIntPoint)aPoint
{
    // Right-click acts as Wiimote A button for player 1
    [self.client didPushWiiButton:OEWiiButtonA forPlayer:1];
    [self mouseMovedAtPoint:aPoint];
}

- (void)rightMouseUpAtPoint
{
    [self.client didReleaseWiiButton:OEWiiButtonA forPlayer:1];
}

@end
