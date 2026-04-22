# LGPL Compliance Information for Subconscious

## Overview

Subconscious includes components licensed under the GNU Lesser General Public License (LGPL). This document explains our compliance with LGPL requirements.

## LGPL Components

### pystray

- **Version**: 0.19.5
- **License**: GNU Lesser General Public License v3 (LGPLv3)
- **Purpose**: System tray functionality for the desktop application
- **Source Repository**: [https://github.com/moses-palmer/pystray](https://github.com/moses-palmer/pystray)
- **License Text**: [https://www.gnu.org/licenses/lgpl-3.0.html](https://www.gnu.org/licenses/lgpl-3.0.html)

## Compliance Measures

In accordance with LGPL requirements, we ensure that:

1. **Source Availability**: The complete source code for LGPL components is available from their upstream repositories.

2. **Modification Rights**: Users have the right to modify the LGPL components and use their modified versions with Subconscious.

3. **No Static Linking Restrictions**: Since Python is dynamically interpreted, and we're distributing source code alongside binaries, users can replace LGPL components as needed.

## For Users

If you wish to modify or update any LGPL components:

1. Obtain the source code from the upstream repository
2. Make your modifications
3. Replace the component in your Subconscious installation
4. The modified version will work with Subconscious due to the dynamic nature of Python imports

## For Developers

When updating dependencies:

1. Check for LGPL components in new versions
2. Ensure source repositories remain accessible
3. Update this document as needed
4. Test that replacement of LGPL components works

## Contact

For questions about LGPL compliance, please contact the Subconscious maintainers. 
