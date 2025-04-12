## Project Notes

Add project-specific notes, documentation and guidelines here.
This file is stored in the project repository.

# Cheater Detection Project Notes

This project is a Lua-based cheater detection system for Lmaobox, designed to identify and track potential cheaters in TF2.

The system is organized into core modules:

- **Database**: Manages storage and retrieval of cheater information
- **Detection Methods**: Contains various techniques to detect suspicious behavior
- **Utils**: Common utilities and helper functions
- **Misc**: Additional components including UI elements

Recent work has focused on improving the database functionality, particularly ensuring that data is saved correctly and efficiently. The implementation uses JSON for data serialization and local file storage to maintain records of known cheaters.

The current architecture allows fetching data from multiple sources, parsing it, and maintaining a unified database of cheater records that can be checked during gameplay.
