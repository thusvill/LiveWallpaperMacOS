/*
 * This file is part of LiveWallpaper – LiveWallpaper App for macOS.
 * Copyright (C) 2025 Bios thusvill
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program.  If not, see <https://www.gnu.org/licenses/>.
 */
#import "LineModule.h"

@implementation LineModule {
  CGFloat _currentX;
  CGFloat _maxHeight;
  BOOL _needsLayoutUpdate;
}

- (instancetype)initWithFrame:(NSRect)frame {
  self = [super initWithFrame:frame];
  if (self) {
    _currentX = 0;
    _maxHeight = 0;
    _needsLayoutUpdate = YES;
  }
  return self;
}


- (BOOL)isFlipped {
  return YES;
}


- (NSSize)intrinsicContentSize {
  if (_needsLayoutUpdate) {
    [self recalculateLayout];
  }
  return NSMakeSize(_currentX, _maxHeight);
}


- (void)recalculateLayout {
  _currentX = 0;
  _maxHeight = 0;

  for (NSView *view in self.subviews) {
    [view sizeToFit];

    NSSize size = view.frame.size;
    if (size.height > _maxHeight)
      _maxHeight = size.height;
  }

  for (NSView *view in self.subviews) {
    NSSize size = view.frame.size;
    CGFloat yOffset = (_maxHeight - size.height) / 2.0;
    [view setFrameOrigin:NSMakePoint(_currentX, yOffset)];
    _currentX += size.width + 8;
  }

  [self setFrameSize:NSMakeSize(_currentX, _maxHeight)];
  _needsLayoutUpdate = NO;
}


- (void)layout {
  [super layout];
  _needsLayoutUpdate = YES;
  [self recalculateLayout];
}


- (void)add:(NSView *)view {
  if (!view) return;

  [self addSubview:view];
  _needsLayoutUpdate = YES;

  [self invalidateIntrinsicContentSize];
  [self setNeedsLayout:YES];
}

- (BOOL)mouseDownCanMoveWindow {
  return NO;
}

- (BOOL)isOpaque {
  return NO;
}

- (BOOL)acceptsFirstResponder {
  return NO;
}

@end
